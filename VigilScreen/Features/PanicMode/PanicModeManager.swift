import AppKit
import LocalAuthentication
import Combine
import QuartzCore

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
class PanicModeManager: ObservableObject {
    static let shared = PanicModeManager()

    @Published private(set) var isActive = false

    private var isAuthenticating = false
    private var panicTask: Task<Void, Never>?
    private var panicCancellables = Set<AnyCancellable>()
    private var shortcutMonitor: Any?
    private let safelist = AppSafelist.shared
    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

    // One overlay per screen, always at .screenSaver (1000) during panic.
    // Safelisted apps are visible through transparent holes in the maskImage —
    // the overlay level never drops, so non-safelisted apps can never flash above it.
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    // Cached "holes for safelisted windows" mask per display. Applying a cached
    // NSImage is instant; rebuilding from AX + CGContext is not (10–50 ms). Without
    // this, activating a safelisted app leaves the full-blur mask in place for a
    // few frames while the rebuild runs — visible as a blur flash.
    private var cachedSafelistMasks: [CGDirectDisplayID: NSImage] = [:]

    // Pending activation work (scheduled after a brief delay so the newly-focused
    // app finishes relaying out its window before we rebuild the mask). Tracked so
    // we can cancel it if another activation comes in first.
    private var pendingActivationWork: DispatchWorkItem?

    // Signature of the last mask we applied — used by the 250ms loop to skip
    // re-applying when nothing changed. NSVisualEffectView.maskImage cross-fades on
    // every assignment, even to an identical image, producing a perceptible shimmer
    // if applied every tick.
    private var lastAppliedSignature: [CGDirectDisplayID: String] = [:]

    // CGEvent tap that intercepts left-mouse-down BEFORE macOS processes it.
    // Used to pre-apply the safelisted hole so there is zero full-blur flash when
    // the user clicks a safelisted app — by the time the activation notification
    // fires the mask is already correct.
    private var clickEventTap: CFMachPort?

    // Vigil Screen's own windows (settings, popover) are raised above the overlay during panic
    // so the user can still interact with them.
    private let panicVigilLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    // During auth the overlay drops to level 1; Vigil Screen windows go to level 2 so they
    // remain visible but don't obstruct the system auth dialog (modal panel, level 8).
    private let authVigilLevel  = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)

    // MARK: - Overlay Window Management

    private func overlayWindow(for screen: NSScreen) -> NSWindow {
        let displayID = screen.displayID
        // Use the full frame so Panic Mode also obscures the menu bar and Dock area.
        let overlay = screen.frame
        if let existing = overlayWindows[displayID] {
            existing.setFrame(overlay, display: false)
            return existing
        }
        let win = NSWindow(
            contentRect: overlay,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        // Always at screenSaver (1000) — never lowered during panic.
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.animationBehavior = .none

        // Two-layer overlay:
        //   1. Dark CALayer-backed NSView — guaranteed to render on every display,
        //      including externals where NSVisualEffectView's compositor blur silently fails.
        //   2. NSVisualEffectView on top — provides the real blur aesthetic where the
        //      compositor can render it (usually the built-in display).
        // applyMasks() masks both simultaneously: CALayer.mask on the cover, .maskImage
        // on the blur. Safelisted-app holes show through both layers.
        let cover = NSView(frame: NSRect(origin: .zero, size: overlay.size))
        cover.wantsLayer = true
        // alpha < 1 keeps the window content non-opaque so NSVisualEffectView's
        // .behindWindow compositor blur engages. The layer is only a fallback for
        // displays where the blur fails to render; the blur on top is opaque enough
        // to hide content where it does render.
        cover.layer?.backgroundColor = NSColor(white: 0.05, alpha: 0.6).cgColor
        cover.autoresizingMask = [.width, .height]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: overlay.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        cover.addSubview(blur)

        win.contentView = cover

        overlayWindows[displayID] = win
        return win
    }

    private func prewarmOverlays() {
        for screen in NSScreen.screens {
            let win = overlayWindow(for: screen)
            win.alphaValue = 0
            win.orderFrontRegardless()
        }
    }

    private func showOverlaysOnAllScreens() {
        for screen in NSScreen.screens {
            let win = overlayWindow(for: screen)
            win.orderFrontRegardless()
            win.alphaValue = 1
        }
    }

    private func setOverlayLevel(_ level: NSWindow.Level) {
        overlayWindows.values.forEach { $0.level = level }
    }

    private func dismissAllOverlays() {
        overlayWindows.values.forEach {
            $0.contentView?.layer?.mask = nil
            $0.level = .screenSaver
            $0.alphaValue = 0
            $0.orderOut(nil)
        }
        cachedSafelistMasks.removeAll()
        lastAppliedSignature.removeAll()
    }

    /// Reconciles overlay windows with the current set of connected displays.
    /// Called when a display is connected or disconnected while panic is active.
    /// Only touches screens that actually changed — existing overlays remain undisturbed.
    private func handleScreenConfigurationChange() {
        guard isActive, !isAuthenticating else { return }
        let currentScreens = NSScreen.screens
        let currentIDs = Set(currentScreens.map { $0.displayID })

        // Remove overlays for disconnected screens
        for id in overlayWindows.keys where !currentIDs.contains(id) {
            overlayWindows[id]?.orderOut(nil)
            overlayWindows.removeValue(forKey: id)
            cachedSafelistMasks.removeValue(forKey: id)
        }

        // Create and show overlays only for newly connected screens
        for screen in currentScreens where overlayWindows[screen.displayID] == nil {
            let win = overlayWindow(for: screen)
            win.alphaValue = 1
            win.orderFrontRegardless()
        }
    }

    // MARK: - Vigil Screen Window Level Management

    private func raiseVigilWindows(to level: NSWindow.Level) {
        for window in NSApplication.shared.windows {
            guard !overlayWindows.values.contains(window) else { continue }
            window.level = level
        }
    }

    private func restoreVigilWindows() {
        for window in NSApplication.shared.windows {
            guard !overlayWindows.values.contains(window) else { continue }
            window.level = .normal
        }
    }

    // MARK: - Overlay Mask (transparent holes for safelisted app windows)

    private func appHasFullscreenWindow(_ app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for window in windows {
            var fullscreenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef) == .success,
               let isFullscreen = fullscreenRef as? Bool,
               isFullscreen {
                return true
            }
        }
        return false
    }

    private func appWindowAppearsOnScreen(pid: pid_t,
                                          screen: NSScreen,
                                          cgWindowList: [[String: Any]],
                                          mainDisplayHeight: CGFloat) -> Bool {
        let screenFrame = screen.frame
        var bestIntersectionArea: CGFloat = 0

        for info in cgWindowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) == pid,
                  let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsNS as CFDictionary),
                  cgBounds.width > 0,
                  cgBounds.height > 50 else { continue }

            let quartzRect = NSRect(
                x: cgBounds.minX,
                y: mainDisplayHeight - cgBounds.minY - cgBounds.height,
                width: cgBounds.width,
                height: cgBounds.height
            )
            let intersection = quartzRect.intersection(screenFrame)
            if !intersection.isNull {
                bestIntersectionArea = max(bestIntersectionArea, intersection.width * intersection.height)
            }
        }

        return bestIntersectionArea > screenFrame.width * screenFrame.height * 0.20
    }

    /// Returns window rects for the given app on `screen`, in screen-local coordinates.
    /// Only returns rects for apps in the safelist; if `onlyApp` is provided, filters to
    /// that single process so holes only appear for the frontmost safelisted app.
    ///
    /// Fullscreen windows are detected with AX because Chromium/YouTube fullscreen can
    /// report partial or transitional CGWindow bounds. Normal windows still use
    /// CGWindowList as the source of truth for actual on-screen bounds.
    private func safelistedWindowRects(for screen: NSScreen,
                                       onlyApp: NSRunningApplication? = nil) -> [NSRect] {
        // CGWindowBounds is in CG global space — y-flip MUST use the primary display's
        // height (the screen with the menu bar), not NSScreen.main which tracks the
        // focused screen and changes as the user moves between displays.
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        let overlay = screen.frame
        let screenBounds = NSRect(origin: .zero, size: overlay.size)
        var rects: [NSRect] = []

        let cgWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  safelist.bundleIDs.contains(id),
                  !app.isHidden,
                  app.activationPolicy == .regular else { continue }
            if let onlyApp, app.processIdentifier != onlyApp.processIdentifier { continue }

            let pid = app.processIdentifier
            if appHasFullscreenWindow(app) {
                if appWindowAppearsOnScreen(pid: pid,
                                            screen: screen,
                                            cgWindowList: cgWindowList,
                                            mainDisplayHeight: mainH) {
                    rects.append(screenBounds)
                }
                continue
            }

            for info in cgWindowList {
                guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                      pid_t(ownerPID) == pid,
                      let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                      let cgBounds = CGRect(dictionaryRepresentation: boundsNS as CFDictionary),
                      cgBounds.width > 0, cgBounds.height > 50 else { continue }

                // CGWindowBounds: top-left origin → flip to AppKit bottom-left.
                let quartzRect = NSRect(x: cgBounds.minX, y: mainH - cgBounds.minY - cgBounds.height,
                                       width: cgBounds.width, height: cgBounds.height)
                let localRect = NSRect(
                    x: quartzRect.origin.x - overlay.origin.x,
                    y: quartzRect.origin.y - overlay.origin.y,
                    width: quartzRect.size.width,
                    height: quartzRect.size.height
                )
                let clipped = localRect.intersection(screenBounds)
                if !clipped.isNull { rects.append(clipped) }
            }
        }
        return rects
    }

    /// Builds a mask image: opaque (white) everywhere except transparent holes over safelisted windows.
    /// NSVisualEffectView.maskImage: transparent pixels receive no visual effect and show through.
    /// Mask is sized to the full-screen overlay because Panic Mode covers the menu bar.
    private func makeMaskImage(for screen: NSScreen, safeRects: [NSRect]) -> NSImage {
        let scale = screen.backingScaleFactor
        let overlaySize = screen.frame.size
        let pw = Int(overlaySize.width  * scale)
        let ph = Int(overlaySize.height * scale)

        guard let ctx = CGContext(
            data: nil,
            width: pw, height: ph,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: overlaySize) }

        // Opaque white = blur applied everywhere by default.
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pw), height: CGFloat(ph)))

        // Clear holes where safelisted app windows sit — content shows through without blur.
        ctx.setBlendMode(.clear)
        for rect in safeRects {
            let px = CGRect(
                x: rect.origin.x * scale,
                y: rect.origin.y * scale,
                width:  rect.size.width  * scale,
                height: rect.size.height * scale
            ).intersection(CGRect(x: 0, y: 0, width: CGFloat(pw), height: CGFloat(ph)))
            if !px.isNull { ctx.fill(px) }
        }

        guard let cg = ctx.makeImage() else { return NSImage(size: overlaySize) }
        return NSImage(cgImage: cg, size: overlaySize)
    }

    /// Rebuilds holes for ALL visible windowed safelisted apps across every screen.
    /// Holes are always shown regardless of which app is frontmost — this eliminates
    /// the blur→hole flash because safelisted content is never fully covered.
    private func rebuildMaskCache() {
        var new: [CGDirectDisplayID: NSImage] = [:]
        for screen in NSScreen.screens {
            let safeRects = safelistedWindowRects(for: screen, onlyApp: nil)
            guard !safeRects.isEmpty else { continue }
            new[screen.displayID] = makeMaskImage(for: screen, safeRects: safeRects)
        }
        cachedSafelistMasks = new
    }

    /// Periodic refresh: queries ALL safelisted apps, builds a signature per display,
    /// and only rebuilds + applies when window positions actually changed.
    /// Skipping no-op ticks avoids unnecessary CALayer repaints.
    private func refreshMaskIfChanged() {
        var newSigs: [CGDirectDisplayID: String] = [:]
        var newMasks: [CGDirectDisplayID: NSImage] = [:]
        var anyChanged = false
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            let safeRects = safelistedWindowRects(for: screen, onlyApp: nil)
            let sig = safeRects
                .map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
                .joined(separator: "|")
            newSigs[displayID] = sig
            if sig != lastAppliedSignature[displayID] { anyChanged = true }
            if !safeRects.isEmpty {
                newMasks[displayID] = makeMaskImage(for: screen, safeRects: safeRects)
            }
        }
        guard anyChanged else { return }
        cachedSafelistMasks = newMasks
        lastAppliedSignature = newSigs
        applyMasks()
    }

    /// Applies cached safelisted-app holes to every overlay. Holes are always shown
    /// regardless of which app is frontmost — removing the frontmostIsNonSafelisted gate
    /// eliminates the blur→hole flash that occurred when switching to a safelisted app.
    private func applyMasks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (displayID, win) in overlayWindows {
            guard let contentLayer = win.contentView?.layer else { continue }
            if let holesMask = cachedSafelistMasks[displayID],
               let cgImg = holesMask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // contentLayer.mask propagates to ALL sublayers including NSVisualEffectView.
                let maskLayer = contentLayer.mask ?? CALayer()
                maskLayer.contents = cgImg
                maskLayer.frame = CGRect(origin: .zero, size: contentLayer.bounds.size)
                contentLayer.mask = maskLayer
            } else {
                contentLayer.mask = nil
            }
            contentLayer.displayIfNeeded()
        }
        CATransaction.commit()
    }

    /// Rebuilds holes for all safelisted apps then applies.
    private func updateOverlayMasks() {
        rebuildMaskCache()
        applyMasks()
    }

    // MARK: - Init

    private init() {
        settings.$panicShortcutEnabled
            .sink { [weak self] (enabled: Bool) in
                if enabled { self?.registerShortcut() } else { self?.unregisterShortcut() }
            }
            .store(in: &cancellables)

        // Refresh the mask when a new app launches during panic — the overlay already covers it.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { [weak self] _ in self?.isActive == true }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateOverlayMasks() }
            .store(in: &cancellables)

        // Clear panic state on screen lock — user must re-login anyway.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.clearWithoutUnhiding() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.clearWithoutUnhiding() }
            .store(in: &cancellables)

        // Reconcile overlays when displays are connected/disconnected during panic.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .filter { [weak self] _ in self?.isActive == true }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleScreenConfigurationChange() }
            .store(in: &cancellables)

        // Pre-warm overlay windows at launch so CALayer backing is allocated before
        // panic triggers. Deferred one runloop to not compete with app startup.
        DispatchQueue.main.async { [weak self] in
            self?.prewarmOverlays()
        }
    }

    // MARK: - Panic

    func triggerPanic() {
        guard !isActive else { return }
        LockHistoryStore.shared.record(.panic)
        closeNotificationCenter()
        hideStageManager()

        isActive = true

        // Raise Vigil Screen's own windows above the overlay so the user can still
        // access settings and the menu bar popover during panic.
        raiseVigilWindows(to: panicVigilLevel)

        // Show blur. Overlays were pre-warmed at launch so this is instant and covers
        // the full screen, including the menu bar and Dock area.
        setOverlayLevel(.screenSaver)
        showOverlaysOnAllScreens()

        // Apply cached masks instantly (nil cache = full blur, safe on first trigger).
        // Defer the expensive AX rebuild so it runs after blur is already on screen.
        applyMasks()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.updateOverlayMasks()
        }

        startMonitoringSpaceSwitches()
        startClickMonitoring()

        // Keep overlays at the top every 250 ms. Rebuild the mask for the current
        // frontmost safelisted app, but ONLY apply it if the window rects actually
        // changed. NSVisualEffectView.maskImage triggers an implicit cross-fade on
        // every assignment (even to an identical image), so applying every tick
        // produces a perceptible shimmer. Skipping no-op applies eliminates it.
        panicTask?.cancel()
        panicTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // 200 ms initial wait
            guard let self, !Task.isCancelled else { return }

            while !Task.isCancelled {
                await MainActor.run { [weak self] in
                    guard let self, self.isActive, !self.isAuthenticating else { return }
                    self.overlayWindows.values.forEach { $0.orderFrontRegardless() }
                    self.refreshMaskIfChanged()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)   // 250 ms
            }
        }
    }

    // MARK: - Notification Center & Stage Manager

    private func closeNotificationCenter() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .forEach { $0.hide() }

        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cgSessionEventTap)
    }

    private func hideStageManager() {
        // Stage Manager stages render above .screenSaver level via WindowManager.
        // Hiding the process removes the stage thumbnails for the duration of panic.
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.WindowManager")
            .forEach { $0.hide() }
    }

    private func unhideStageManager() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.WindowManager")
            .forEach { $0.unhide() }
    }

    // MARK: - Space Switch Monitoring

    private func startMonitoringSpaceSwitches() {
        let center = NSWorkspace.shared.notificationCenter

        // On window switch, close stale holes synchronously before opening a new
        // safelisted hole after WindowServer has settled. This avoids one-frame
        // flashes where the previous app's transparent mask reveals the wrong content.
        //
        // No `.receive(on: DispatchQueue.main)`: NSWorkspace notifications are already
        // posted on the main thread, and adding the hop queues our handler for the NEXT
        // runloop iteration — enough latency for the compositor to render one frame with
        // the new window order but the stale mask (the "blur flash").
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in self?.updateBlurOverlay(for: app) }
            .store(in: &panicCancellables)

        // On Space switch, bring overlays to the front of the screenSaver level.
        center.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.isAuthenticating else { return }
                self.overlayWindows.values.forEach { $0.orderFrontRegardless() }
            }
            .store(in: &panicCancellables)
    }

    private func isSafelisted(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map { safelist.bundleIDs.contains($0) } ?? false
    }

    // MARK: - Pre-emptive click tap

    private func startClickMonitoring() {
        guard clickEventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                // Tap is added to the main run loop, so this runs on the main thread.
                if let refcon {
                    let mgr = Unmanaged<PanicModeManager>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { mgr.preemptiveHoleUpdate(at: event.location) }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: ptr
        ) else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        clickEventTap = tap
    }

    private func stopClickMonitoring() {
        if let tap = clickEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            clickEventTap = nil
        }
    }

    /// Hit-tests `cgPoint` (CG top-left coordinates) against on-screen windows.
    /// If the topmost non-overlay window belongs to a safelisted app, immediately
    /// rebuilds and applies its hole mask — BEFORE macOS activates the window.
    /// This eliminates the one-frame full-blur flash that notification-based updates
    /// cannot avoid.
    private func preemptiveHoleUpdate(at cgPoint: CGPoint) {
        guard isActive, !isAuthenticating else { return }
        let overlayNums = Set(overlayWindows.values.map { $0.windowNumber })
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for info in windowList {
            // Skip our own overlay windows — they have ignoresMouseEvents = true so
            // clicks pass through; they'd always be the topmost hit otherwise.
            if let num = info[kCGWindowNumber as String] as? Int,
               overlayNums.contains(num) { continue }
            guard let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsNS as CFDictionary),
                  cgBounds.width > 1, cgBounds.height > 10,
                  cgBounds.contains(cgPoint) else { continue }
            guard info[kCGWindowOwnerPID as String] is Int else { break }
            // Whether the clicked window is safelisted or not, rebuild all holes
            // so the mask is current at the moment the window activates.
            rebuildMaskCache()
            lastAppliedSignature.removeAll()
            applyMasks()
            break
        }
    }

    private func updateBlurOverlay(for app: NSRunningApplication) {
        guard isActive, !isAuthenticating else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        // A previous activation may have a pending "reapply" queued. Cancel it
        // so a rapid second switch doesn't stomp on this one's final state.
        pendingActivationWork?.cancel()
        pendingActivationWork = nil

        overlayWindows.values.forEach { $0.orderFrontRegardless() }
        setOverlayAlphaInstant(1, only: nil)

        // Rebuild holes for ALL safelisted apps and apply immediately.
        // Safelisted holes are always visible regardless of what's frontmost, so
        // there is no blur→hole flash on any transition.
        rebuildMaskCache()
        lastAppliedSignature.removeAll()
        applyMasks()

        // Two refinement passes for apps that reflow their windows after activation.
        let firstPass = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, !self.isAuthenticating else { return }
            self.rebuildMaskCache()
            self.applyMasks()

            let secondPass = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.isAuthenticating else { return }
                self.rebuildMaskCache()
                self.applyMasks()
                self.pendingActivationWork = nil
            }
            self.pendingActivationWork = secondPass
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: secondPass)
        }

        pendingActivationWork = firstPass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: firstPass)
    }

    /// Smoothly fades the overlay alpha over `duration` seconds. Uses the window
    /// animator proxy so the change is driven by the display link, not an abrupt set.
    /// When `only` is provided, only the overlay on that display is affected.
    private func fadeOverlayAlpha(to alpha: CGFloat, duration: TimeInterval, only displayID: CGDirectDisplayID? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if let displayID, let win = overlayWindows[displayID] {
                win.animator().alphaValue = alpha
            } else {
                for win in overlayWindows.values {
                    win.animator().alphaValue = alpha
                }
            }
        }
    }

    /// Sets overlay alpha with no implicit animation — applied this frame.
    /// macOS wraps NSWindow.alphaValue in an implicit animation inside an
    /// NSAnimationContext; wrapping in a disabled-actions CATransaction and
    /// forcing the backing layer to display suppresses the fade.
    /// When `only` is provided, only the overlay on that display is affected.
    private func setOverlayAlphaInstant(_ alpha: CGFloat, only displayID: CGDirectDisplayID? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let displayID, let win = overlayWindows[displayID] {
                win.alphaValue = alpha
                win.contentView?.layer?.displayIfNeeded()
            } else {
                for win in overlayWindows.values {
                    win.alphaValue = alpha
                    win.contentView?.layer?.displayIfNeeded()
                }
            }
            CATransaction.commit()
        }
    }

    // MARK: - Release

    func releasePanic() {
        guard isActive else { return }
        if settings.panicRequiresTouchID {
            isAuthenticating = true
            // Lower overlay to level 1 — above normal app windows (0) but below the
            // system auth dialog (modal panel, level 8) so it remains visible.
            // Lower Vigil Screen windows to level 2: visible but below the auth dialog.
            setOverlayLevel(NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1))
            raiseVigilWindows(to: authVigilLevel)
            overlayWindows.values.forEach { $0.orderFrontRegardless() }

            authenticateWithBiometrics { [weak self] success in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unhideAll()
                } else {
                    // Restore full overlay protection after failed auth.
                    self.setOverlayLevel(.screenSaver)
                    self.raiseVigilWindows(to: self.panicVigilLevel)
                    self.showOverlaysOnAllScreens()
                    self.updateOverlayMasks()
                }
            }
        } else {
            unhideAll()
        }
    }

    /// Releases panic mode immediately without biometric authentication.
    /// Used by ShoulderSurfingDetector auto-release when the threat is confirmed gone.
    func releasePanicWithoutAuth() {
        guard isActive, !isAuthenticating else { return }
        unhideAll()
    }

    private func unhideAll() {
        panicTask?.cancel()
        panicTask = nil
        pendingActivationWork?.cancel()
        pendingActivationWork = nil
        isAuthenticating = false
        panicCancellables.removeAll()
        stopClickMonitoring()
        restoreVigilWindows()
        dismissAllOverlays()
        unhideStageManager()
        isActive = false
    }

    private func clearWithoutUnhiding() {
        panicTask?.cancel()
        panicTask = nil
        pendingActivationWork?.cancel()
        pendingActivationWork = nil
        isAuthenticating = false
        panicCancellables.removeAll()
        stopClickMonitoring()
        restoreVigilWindows()
        dismissAllOverlays()
        isActive = false
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @MainActor @escaping (Bool) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "unlock Vigil Screen Panic Mode") { success, authError in
            Task { @MainActor in
                if !success, SettingsStore.shared.intruderCaptureEnabled {
                    let isSystemCancel = (authError as? LAError)?.code == .systemCancel
                    if !isSystemCancel {
                        IntruderCaptureManager.shared.capturePhoto { filename in
                            LockHistoryStore.shared.record(.intruderCapture, photoFilename: filename)
                        }
                    }
                }
                completion(success)
            }
        }
    }

    // MARK: - Global Shortcut (⌘ + Shift + L)

    private func registerShortcut() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == [.command, .shift], event.keyCode == 37 else { return } // 37 = L
            if self.isActive { self.releasePanic() } else { self.triggerPanic() }
        }
    }

    private func unregisterShortcut() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }
}
