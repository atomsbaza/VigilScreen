import AppKit
import LocalAuthentication
import Combine
import QuartzCore

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
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

    // DockLock's own windows (settings, popover) are raised above the overlay during panic
    // so the user can still interact with them.
    private let panicVigilLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    // During auth the overlay drops to level 1; DockLock windows go to level 2 so they
    // remain visible but don't obstruct the system auth dialog (modal panel, level 8).
    private let authVigilLevel  = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)

    // MARK: - Overlay Window Management

    private func overlayWindow(for screen: NSScreen) -> NSWindow {
        let displayID = screen.displayID
        if let existing = overlayWindows[displayID] {
            existing.setFrame(screen.frame, display: false)
            return existing
        }
        let win = NSWindow(
            contentRect: screen.frame,
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

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        win.contentView = blur

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
            ($0.contentView as? NSVisualEffectView)?.maskImage = nil
            $0.level = .screenSaver
            $0.alphaValue = 0
            $0.orderOut(nil)
        }
        cachedSafelistMasks.removeAll()
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

    /// Returns window rects for all visible safelisted apps, in screen-local coordinates.
    private func safelistedWindowRects(for screen: NSScreen) -> [NSRect] {
        let mainH = NSScreen.main?.frame.height ?? 0
        let screenBounds = NSRect(origin: .zero, size: screen.frame.size)
        var rects: [NSRect] = []

        // CGWindowList snapshot — queried once per call, shared across all apps.
        // More reliable than AX for apps with limited accessibility support (e.g. Chrome/Electron).
        let cgWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  safelist.bundleIDs.contains(id),
                  !app.isHidden,
                  app.activationPolicy == .regular else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let axOK = AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success
            let axWindows = windowsRef as? [AXUIElement] ?? []

            if axOK && !axWindows.isEmpty {
                for window in axWindows {
                    // Fullscreen windows occupy the entire screen; punch a full-screen hole
                    // rather than going through the normal coordinate conversion (which can
                    // produce out-of-bounds rects for fullscreen AX positions).
                    var fullscreenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef) == .success,
                       let isFS = fullscreenRef as? Bool, isFS {
                        rects.append(NSRect(origin: .zero, size: screen.frame.size))
                        continue
                    }

                    var posRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window, "AXPosition" as CFString, &posRef) == .success,
                          AXUIElementCopyAttributeValue(window, "AXSize" as CFString, &sizeRef) == .success,
                          let posAX = posRef, let sizeAX = sizeRef else { continue }

                    var axPos  = CGPoint.zero
                    var axSize = CGSize.zero
                    guard CFGetTypeID(posAX) == AXValueGetTypeID(),
                          CFGetTypeID(sizeAX) == AXValueGetTypeID() else { continue }
                    AXValueGetValue(posAX as! AXValue, .cgPoint, &axPos)
                    AXValueGetValue(sizeAX as! AXValue, .cgSize,  &axSize)

                    // Convert AX coords (top-left origin, y increases downward) to
                    // Quartz display coords (bottom-left origin, y increases upward).
                    let quartzRect = NSRect(
                        x: axPos.x,
                        y: mainH - axPos.y - axSize.height,
                        width: axSize.width,
                        height: axSize.height
                    )
                    // Translate to overlay window-local coordinates (origin = screen.frame.origin).
                    let localRect = NSRect(
                        x: quartzRect.origin.x - screen.frame.origin.x,
                        y: quartzRect.origin.y - screen.frame.origin.y,
                        width: quartzRect.size.width,
                        height: quartzRect.size.height
                    )
                    let clipped = localRect.intersection(screenBounds)
                    if !clipped.isNull { rects.append(clipped) }
                }
            } else {
                // AX gave no windows (common for Chrome/Electron apps). Fall back to
                // CGWindowList which works for all apps regardless of AX support.
                // CGWindowBounds also uses top-left origin so the same y-flip applies.
                let pid = app.processIdentifier
                for info in cgWindowList {
                    // kCGWindowOwnerPID bridges as Int (not Int32/pid_t) from CFNumber.
                    // kCGWindowBounds bridges as NSDictionary — use CGRect(dictionaryRepresentation:).
                    guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                          pid_t(ownerPID) == pid,
                          let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                          let cgBounds = CGRect(dictionaryRepresentation: boundsNS as CFDictionary),
                          cgBounds.width > 0, cgBounds.height > 50 else { continue }

                    // CGWindowBounds: top-left origin (same as AX) → flip to Quartz bottom-left.
                    let quartzRect = NSRect(x: cgBounds.minX, y: mainH - cgBounds.minY - cgBounds.height,
                                           width: cgBounds.width, height: cgBounds.height)
                    let localRect = NSRect(
                        x: quartzRect.origin.x - screen.frame.origin.x,
                        y: quartzRect.origin.y - screen.frame.origin.y,
                        width: quartzRect.size.width,
                        height: quartzRect.size.height
                    )
                    let clipped = localRect.intersection(screenBounds)
                    if !clipped.isNull { rects.append(clipped) }
                }
            }
        }
        return rects
    }

    /// Builds a mask image: opaque (white) everywhere except transparent holes over safelisted windows.
    /// NSVisualEffectView.maskImage: transparent pixels receive no visual effect and show through.
    private func makeMaskImage(for screen: NSScreen, safeRects: [NSRect]) -> NSImage {
        let scale = screen.backingScaleFactor
        let pw = Int(screen.frame.width  * scale)
        let ph = Int(screen.frame.height * scale)

        guard let ctx = CGContext(
            data: nil,
            width: pw, height: ph,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: screen.frame.size) }

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

        guard let cg = ctx.makeImage() else { return NSImage(size: screen.frame.size) }
        return NSImage(cgImage: cg, size: screen.frame.size)
    }

    /// Rebuilds the cached safelist mask (one per screen) from current AX window rects.
    /// Expensive — do not call on the hot path of an app-activation notification.
    private func rebuildMaskCache() {
        var new: [CGDirectDisplayID: NSImage] = [:]
        for screen in NSScreen.screens {
            let safeRects = safelistedWindowRects(for: screen)
            guard !safeRects.isEmpty else { continue }
            new[screen.displayID] = makeMaskImage(for: screen, safeRects: safeRects)
        }
        cachedSafelistMasks = new
    }

    /// Applies the right mask to each overlay based on what's frontmost, using only
    /// the cached mask images. Runs in constant time — safe for activation callbacks.
    /// If the frontmost app is non-safelisted, applies full blur with no holes —
    /// preventing safelisted holes from revealing content of overlapping non-safelisted apps.
    ///
    /// Pass `frontmostApp` directly from a `didActivate` notification when available —
    /// `NSWorkspace.shared.frontmostApplication` can briefly lag the notification.
    private func applyMasks(frontmostApp: NSRunningApplication? = nil) {
        let resolved = frontmostApp ?? NSWorkspace.shared.frontmostApplication
        let frontmostIsNonSafelisted = resolved.map { app -> Bool in
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            return !isSafelisted(app) && app.activationPolicy == .regular
        } ?? false

        // Wrap in a CATransaction with actions disabled: setting `maskImage` on an
        // NSVisualEffectView otherwise triggers an implicit crossfade between masks,
        // which itself reads as a "blur flash" when swapping nil ↔ holes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (displayID, win) in overlayWindows {
            guard let effectView = win.contentView as? NSVisualEffectView else { continue }
            effectView.maskImage = frontmostIsNonSafelisted ? nil : cachedSafelistMasks[displayID]
            effectView.layer?.displayIfNeeded()
        }
        CATransaction.commit()
    }

    /// Refreshes cache then applies. Used by the periodic loop and on panic start.
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
    }

    // MARK: - Panic

    func triggerPanic() {
        guard !isActive else { return }
        LockHistoryStore.shared.record(.panic)
        closeNotificationCenter()

        isActive = true

        // Raise DockLock's own windows above the overlay so the user can still
        // access settings and the menu bar popover during panic.
        raiseVigilWindows(to: panicVigilLevel)

        prewarmOverlays()
        setOverlayLevel(.screenSaver)
        showOverlaysOnAllScreens()
        updateOverlayMasks()
        startMonitoringSpaceSwitches()

        // Continuously keep overlays at the top of the screenSaver level and refresh
        // the maskImage so safelisted window positions stay accurate as windows move.
        panicTask?.cancel()
        panicTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // 200 ms initial wait
            guard let self, !Task.isCancelled else { return }

            while !Task.isCancelled {
                await MainActor.run { [weak self] in
                    guard let self, self.isActive, !self.isAuthenticating else { return }
                    self.overlayWindows.values.forEach { $0.orderFrontRegardless() }
                    self.updateOverlayMasks()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)   // 250 ms
            }
        }
    }

    // MARK: - Notification Center

    private func closeNotificationCenter() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .forEach { $0.hide() }

        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Space Switch Monitoring

    private func startMonitoringSpaceSwitches() {
        let center = NSWorkspace.shared.notificationCenter

        // On window switch, immediately update the mask: opens a hole for safelisted apps,
        // keeps the overlay covering non-safelisted apps — no waiting for the 250 ms loop.
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

    private func updateBlurOverlay(for app: NSRunningApplication) {
        guard isActive, !isAuthenticating else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        // A previous activation may have a pending "reapply" queued. Cancel it
        // so a rapid second switch doesn't stomp on this one's final state.
        pendingActivationWork?.cancel()
        pendingActivationWork = nil

        if !isSafelisted(app) && app.activationPolicy == .regular {
            // Non-safelisted: apply full blur synchronously. Nothing to settle,
            // so no delay needed — the user never sees an un-blurred frame.
            setOverlayAlphaInstant(1)
            overlayWindows.values.forEach { $0.orderFrontRegardless() }
            applyMasks(frontmostApp: app)
        } else {
            // Safelisted: clear the blur immediately (alpha 0), then re-check and
            // re-apply after the new window finishes its on-activation relayout.
            //
            // During the delay the cached mask is not shown at all, so a stale or
            // narrow hole can't reveal itself. When the delay expires we rebuild
            // from the settled AX rect and snap the overlay back in with correct
            // holes. Both alpha transitions are wrapped in a disabled-actions
            // CATransaction + forced display so they happen this frame, not via
            // an implicit Core Animation fade.
            setOverlayAlphaInstant(0)

            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.isAuthenticating else { return }

                // Re-evaluate frontmost at fire time — the user may have switched
                // again during the delay; rebuild for whoever is actually frontmost.
                let current = NSWorkspace.shared.frontmostApplication
                let currentIsNonSafelisted = current.map { c -> Bool in
                    guard c.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
                    return !self.isSafelisted(c) && c.activationPolicy == .regular
                } ?? false

                if !currentIsNonSafelisted {
                    self.rebuildMaskCache()
                }
                self.applyMasks(frontmostApp: current)
                // Fade back in instead of snapping — any remaining inaccuracy in the
                // mask reads as a gentle reveal rather than a sharp flash. The 250 ms
                // background loop re-rebuilds the cache mid-fade, so slow-settling
                // windows correct themselves while the overlay is still transparent.
                self.fadeOverlayAlpha(to: 1, duration: 0.18)
                self.pendingActivationWork = nil
            }
            pendingActivationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        }
    }

    /// Smoothly fades the overlay alpha over `duration` seconds. Uses the window
    /// animator proxy so the change is driven by the display link, not an abrupt set.
    private func fadeOverlayAlpha(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for win in overlayWindows.values {
                win.animator().alphaValue = alpha
            }
        }
    }

    /// Sets overlay alpha with no implicit animation — applied this frame.
    /// macOS wraps NSWindow.alphaValue in an implicit animation inside an
    /// NSAnimationContext; wrapping in a disabled-actions CATransaction and
    /// forcing the backing layer to display suppresses the fade.
    private func setOverlayAlphaInstant(_ alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for win in overlayWindows.values {
                win.alphaValue = alpha
                win.contentView?.layer?.displayIfNeeded()
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
            // Lower DockLock windows to level 2: visible but below the auth dialog.
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
        restoreVigilWindows()
        dismissAllOverlays()
        isActive = false
    }

    private func clearWithoutUnhiding() {
        panicTask?.cancel()
        panicTask = nil
        pendingActivationWork?.cancel()
        pendingActivationWork = nil
        isAuthenticating = false
        panicCancellables.removeAll()
        restoreVigilWindows()
        dismissAllOverlays()
        isActive = false
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @MainActor @escaping (Bool) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Unlock Vigil Screen Panic Mode") { success, authError in
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
