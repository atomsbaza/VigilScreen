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

    // Vigil Screen's own windows (settings, popover) are raised above the overlay during panic
    // so the user can still interact with them.
    private let panicVigilLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    // During auth the overlay drops to level 1; Vigil Screen windows go to level 2 so they
    // remain visible but don't obstruct the system auth dialog (modal panel, level 8).
    private let authVigilLevel  = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)

    // MARK: - Overlay Window Management

    private func overlayWindow(for screen: NSScreen) -> NSWindow {
        let displayID = screen.displayID
        // visibleFrame excludes the menu bar (and Dock when not auto-hidden), so the
        // system menu bar stays fully unobscured by our overlay or its blur effect.
        let overlay = screen.visibleFrame
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
            ($0.contentView?.subviews.first as? NSVisualEffectView)?.maskImage = nil
            $0.level = .screenSaver
            $0.alphaValue = 0
            $0.orderOut(nil)
        }
        cachedSafelistMasks.removeAll()
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

    /// Returns window rects for the given app on `screen`, in screen-local coordinates.
    /// Only returns rects for apps in the safelist; if `onlyApp` is provided, filters to
    /// that single process so holes only appear for the frontmost safelisted app.
    ///
    /// Uses CGWindowList as the source of truth for window bounds — AX size is
    /// unreliable for Chromium/Electron apps (it sometimes returns the inner content
    /// view or a child window rather than the actual top-level window). AX is only
    /// consulted for the fullscreen flag, which CGWindowList doesn't expose.
    private func safelistedWindowRects(for screen: NSScreen,
                                       onlyApp: NSRunningApplication? = nil) -> [NSRect] {
        // CGWindowBounds is in CG global space — y-flip MUST use the primary display's
        // height (the screen with the menu bar), not NSScreen.main which tracks the
        // focused screen and changes as the user moves between displays. When primary
        // and focused screens have different heights, NSScreen.main produces a wrong
        // offset that shifts every hole vertically.
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        // The overlay covers visibleFrame, not the full screen.frame — all rects must
        // be translated relative to visibleFrame.origin and clipped to visibleFrame.size.
        let overlay = screen.visibleFrame
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

            // Probe AX only for the fullscreen flag. If any window is fullscreen,
            // punch a full-screen hole and skip CGWindowList lookup for this app —
            // fullscreen AX positions are unreliable but the result is always "everything".
            var appIsFullscreen = false
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success,
               let axWindows = windowsRef as? [AXUIElement] {
                for window in axWindows {
                    var fullscreenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef) == .success,
                       let isFS = fullscreenRef as? Bool, isFS {
                        appIsFullscreen = true
                        break
                    }
                }
            }
            if appIsFullscreen {
                rects.append(NSRect(origin: .zero, size: overlay.size))
                continue
            }

            // CGWindowBounds: top-left origin (same as AX) → flip to AppKit bottom-left.
            let pid = app.processIdentifier
            for info in cgWindowList {
                // kCGWindowOwnerPID bridges as Int from CFNumber.
                // kCGWindowBounds bridges as NSDictionary — use CGRect(dictionaryRepresentation:).
                guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                      pid_t(ownerPID) == pid,
                      let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                      let cgBounds = CGRect(dictionaryRepresentation: boundsNS as CFDictionary),
                      cgBounds.width > 0, cgBounds.height > 50 else { continue }

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
    /// Mask is sized to the overlay (visibleFrame), not the full screen, since that's
    /// what the cover layer and blur view are sized to.
    private func makeMaskImage(for screen: NSScreen, safeRects: [NSRect]) -> NSImage {
        let scale = screen.backingScaleFactor
        let overlaySize = screen.visibleFrame.size
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

    /// Rebuilds the cached safelist mask for `app` only (one entry per screen).
    /// Passing nil clears the cache — used when no safelisted app is frontmost.
    /// Expensive — do not call on the hot path of an app-activation notification.
    private func rebuildMaskCache(for app: NSRunningApplication?) {
        guard let app, isSafelisted(app) else {
            cachedSafelistMasks.removeAll()
            return
        }
        var new: [CGDirectDisplayID: NSImage] = [:]
        for screen in NSScreen.screens {
            let safeRects = safelistedWindowRects(for: screen, onlyApp: app)
            guard !safeRects.isEmpty else { continue }
            new[screen.displayID] = makeMaskImage(for: screen, safeRects: safeRects)
        }
        cachedSafelistMasks = new
    }

    /// Applies the right mask to each overlay based on what's frontmost, using only
    /// the cached mask images. Runs in constant time — safe for activation callbacks.
    /// If the frontmost app is non-safelisted, removes any holes (full dark coverage) —
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (displayID, win) in overlayWindows {
            guard let cover = win.contentView, let contentLayer = cover.layer else { continue }
            let blur = cover.subviews.first as? NSVisualEffectView
            let holesMask = frontmostIsNonSafelisted ? nil : cachedSafelistMasks[displayID]
            if let holesMask,
               let cgImg = holesMask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Mask the dark cover layer so safelisted windows show through.
                let maskLayer = contentLayer.mask ?? CALayer()
                maskLayer.contents = cgImg
                maskLayer.frame = CGRect(origin: .zero, size: contentLayer.bounds.size)
                contentLayer.mask = maskLayer
                // Mask the blur layer the same way so the blur also has holes.
                blur?.maskImage = holesMask
            } else {
                contentLayer.mask = nil   // full coverage, no holes
                blur?.maskImage = nil
            }
            contentLayer.displayIfNeeded()
        }
        CATransaction.commit()
    }

    /// Refreshes cache then applies. Holes are built for the current frontmost safelisted app only.
    private func updateOverlayMasks() {
        rebuildMaskCache(for: NSWorkspace.shared.frontmostApplication)
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

        // Show blur. Overlays were pre-warmed at launch so this is instant (no
        // window allocation). The system menu bar is intentionally left visible —
        // covering it would require switching to .regular policy and force-activating
        // Vigil Screen, which fights every safelisted-app activation and complicates
        // the panic flow. The menu bar doesn't expose screen content, only the
        // previously-active app's name + system status.
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

        // Keep overlays at the top every 250 ms and refresh the mask for the current
        // frontmost safelisted app so window moves/resizes are picked up. Per-app
        // rebuild only queries one process (~2–8 ms), unlike the old all-safelisted
        // rebuild which scanned every safelisted process (50–200 ms).
        panicTask?.cancel()
        panicTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // 200 ms initial wait
            guard let self, !Task.isCancelled else { return }

            while !Task.isCancelled {
                await MainActor.run { [weak self] in
                    guard let self, self.isActive, !self.isAuthenticating else { return }
                    self.overlayWindows.values.forEach { $0.orderFrontRegardless() }
                    if let frontmost = NSWorkspace.shared.frontmostApplication,
                       self.isSafelisted(frontmost) {
                        self.rebuildMaskCache(for: frontmost)
                        self.applyMasks(frontmostApp: frontmost)
                    }
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
            setOverlayAlphaInstant(1, only: nil)  // all screens
            overlayWindows.values.forEach { $0.orderFrontRegardless() }
            applyMasks(frontmostApp: app)
        } else {
            // Safelisted: apply mask immediately at current positions, then rebuild
            // with settled positions after the app finishes its on-activation relayout.
            // No alpha tricks needed — CALayer mask updates are instantaneous and
            // don't produce visual artifacts on any display.
            applyMasks(frontmostApp: app)

            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.isAuthenticating else { return }
                let current = NSWorkspace.shared.frontmostApplication
                let currentIsNonSafelisted = current.map { c -> Bool in
                    guard c.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
                    return !self.isSafelisted(c) && c.activationPolicy == .regular
                } ?? false
                if !currentIsNonSafelisted {
                    // Only build holes for the current frontmost safelisted app.
                    // Other safelisted apps on other screens are intentionally hidden.
                    self.rebuildMaskCache(for: current)
                }
                self.applyMasks(frontmostApp: current)
                self.pendingActivationWork = nil
            }
            pendingActivationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        }
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
