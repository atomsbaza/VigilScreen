import AppKit
import LocalAuthentication
import Combine

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}

@MainActor
class PanicModeManager: ObservableObject {
    static let shared = PanicModeManager()

    @Published private(set) var isActive = false

    // All apps hidden during panic (windowed non-safelisted).
    // Tracked so they can be unhidden on release.
    private var hiddenApps: [NSRunningApplication] = []
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

    // DockLock's own windows (settings, popover) are raised above the overlay during panic
    // so the user can still interact with them.
    private let panicDockLockLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    // During auth the overlay drops to level 1; DockLock windows go to level 2 so they
    // remain visible but don't obstruct the system auth dialog (modal panel, level 8).
    private let authDockLockLevel  = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)

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
    }

    // MARK: - DockLock Window Level Management

    private func raiseDockLockWindows(to level: NSWindow.Level) {
        for window in NSApplication.shared.windows {
            guard !overlayWindows.values.contains(window) else { continue }
            window.level = level
        }
    }

    private func restoreDockLockWindows() {
        for window in NSApplication.shared.windows {
            guard !overlayWindows.values.contains(window) else { continue }
            window.level = .normal
        }
    }

    // MARK: - Overlay Mask (transparent holes for safelisted app windows)

    /// Returns window rects for all visible safelisted apps, in screen-local coordinates.
    private func safelistedWindowRects(for screen: NSScreen) -> [NSRect] {
        let mainH = NSScreen.main?.frame.height ?? 0
        var rects: [NSRect] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  safelist.bundleIDs.contains(id),
                  !app.isHidden,
                  app.activationPolicy == .regular else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
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
                let clipped = localRect.intersection(NSRect(origin: .zero, size: screen.frame.size))
                if !clipped.isNull { rects.append(clipped) }
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

    /// Refreshes each overlay's maskImage so safelisted app windows show through unblurred.
    private func updateOverlayMasks() {
        for (displayID, win) in overlayWindows {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }),
                  let effectView = win.contentView as? NSVisualEffectView else { continue }
            let safeRects = safelistedWindowRects(for: screen)
            effectView.maskImage = safeRects.isEmpty ? nil : makeMaskImage(for: screen, safeRects: safeRects)
        }
    }

    // MARK: - Init

    private init() {
        settings.$panicShortcutEnabled
            .sink { [weak self] (enabled: Bool) in
                if enabled { self?.registerShortcut() } else { self?.unregisterShortcut() }
            }
            .store(in: &cancellables)

        // Hide apps that launch while panic is active and are not in the safelist.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { [weak self] app in
                guard let self, self.isActive else { return false }
                guard let id = app.bundleIdentifier else { return false }
                return app.activationPolicy == .regular && !self.safelist.bundleIDs.contains(id)
            }
            .sink { [weak self] app in
                app.hide()
                if !(self?.hiddenApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) ?? false) {
                    self?.hiddenApps.append(app)
                }
            }
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

    private func exitFullScreenIfNeeded(_ app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for window in windows {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &valueRef) == .success,
                  let ref = valueRef,
                  CFGetTypeID(ref) == CFBooleanGetTypeID(),
                  (ref as! CFBoolean) == kCFBooleanTrue else { continue }
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        }
    }

    private func hasFullScreenWindow(_ app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &valueRef) == .success,
                  let ref = valueRef,
                  CFGetTypeID(ref) == CFBooleanGetTypeID() else { continue }
            if (ref as! CFBoolean) == kCFBooleanTrue { return true }
        }
        return false
    }

    func triggerPanic() {
        guard !isActive else { return }
        LockHistoryStore.shared.record(.panic)
        closeNotificationCenter()

        let ownID = Bundle.main.bundleIdentifier
        let nonSafelisted = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return $0.activationPolicy == .regular
                && !safelist.bundleIDs.contains(id)
                && id != ownID
        }

        // Full-screen apps: covered by the always-screenSaver overlay — not hidden.
        // Windowed apps: hidden so they don't consume resources while covered.
        hiddenApps = nonSafelisted.filter { !hasFullScreenWindow($0) }
        hiddenApps.forEach { $0.hide() }

        isActive = true

        // Raise DockLock's own windows above the overlay so the user can still
        // access settings and the menu bar popover during panic.
        raiseDockLockWindows(to: panicDockLockLevel)

        prewarmOverlays()
        setOverlayLevel(.screenSaver)
        showOverlaysOnAllScreens()
        updateOverlayMasks()
        startMonitoringSpaceSwitches()

        // Phase 2: continuously enforce hiding of non-safelisted windowed apps and
        // refresh the maskImage to track safelisted app window positions.
        //
        // The overlay stays at .screenSaver permanently — it is never lowered.
        // Safelisted apps are visible through transparent holes in maskImage.
        // This eliminates the flash that occurred when a hidden app briefly appeared
        // above the old lower-level overlay before the notification handler could react.
        panicTask?.cancel()
        panicTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // 200 ms initial wait
            guard let self, !Task.isCancelled else { return }

            while !Task.isCancelled {
                await MainActor.run { [weak self] in
                    guard let self, self.isActive, !self.isAuthenticating else { return }

                    let ownID = Bundle.main.bundleIdentifier
                    let allApps = NSWorkspace.shared.runningApplications.filter { app in
                        guard let id = app.bundleIdentifier else { return false }
                        return app.activationPolicy == .regular
                            && !self.safelist.bundleIDs.contains(id)
                            && id != ownID
                    }

                    // Hide any windowed non-safelisted app that became visible.
                    // Catches apps unhidden by the user and apps that exited full-screen.
                    let windowedVisible = allApps.filter { !$0.isHidden && !self.hasFullScreenWindow($0) }
                    windowedVisible.forEach { app in
                        if !self.hiddenApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                            self.hiddenApps.append(app)
                        }
                        app.hide()
                    }

                    // Keep overlays at the top of the screenSaver level.
                    self.overlayWindows.values.forEach { $0.orderFrontRegardless() }

                    // Refresh mask: update transparent holes for safelisted app windows
                    // so their current positions/sizes are reflected accurately.
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
        let ownID = Bundle.main.bundleIdentifier

        // If a windowed non-safelisted app gets unhidden by external means, re-hide it.
        // The overlay at screenSaver level already covers it visually; calling hide()
        // removes the window from the compositor entirely.
        center.publisher(for: NSWorkspace.didUnhideApplicationNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { [weak self] app in
                guard let self else { return false }
                return !self.isSafelisted(app)
                    && app.activationPolicy == .regular
                    && app.bundleIdentifier != ownID
                    && !self.hasFullScreenWindow(app)
            }
            .sink { [weak self] app in
                guard let self else { return }
                self.overlayWindows.values.forEach { $0.orderFrontRegardless() }
                app.hide()
            }
            .store(in: &panicCancellables)

        // If a non-safelisted app activates, ensure it is hidden.
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in self?.updateBlurOverlay(for: app) }
            .store(in: &panicCancellables)

        // On Space switch, bring overlays to the front of the screenSaver level.
        center.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
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
        guard isActive else { return }
        if isAuthenticating { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        if !isSafelisted(app) && app.activationPolicy == .regular {
            // Overlay is already at screenSaver (1000) — just bring it to the very front
            // and hide the app so it doesn't consume resources behind the overlay.
            overlayWindows.values.forEach { $0.orderFrontRegardless() }
            if !hasFullScreenWindow(app) {
                app.hide()
            }
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
            raiseDockLockWindows(to: authDockLockLevel)
            overlayWindows.values.forEach { $0.orderFrontRegardless() }

            authenticateWithBiometrics { [weak self] success in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unhideAll()
                } else {
                    // Restore full overlay protection after failed auth.
                    self.setOverlayLevel(.screenSaver)
                    self.raiseDockLockWindows(to: self.panicDockLockLevel)
                    self.showOverlaysOnAllScreens()
                    self.updateOverlayMasks()
                }
            }
        } else {
            unhideAll()
        }
    }

    private func unhideAll() {
        panicTask?.cancel()
        panicTask = nil
        hiddenApps.forEach { $0.unhide() }
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        restoreDockLockWindows()
        dismissAllOverlays()
        isActive = false
    }

    private func clearWithoutUnhiding() {
        panicTask?.cancel()
        panicTask = nil
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        restoreDockLockWindows()
        dismissAllOverlays()
        isActive = false
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @MainActor @escaping (Bool) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Unlock DockLock Panic Mode") { success, authError in
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
