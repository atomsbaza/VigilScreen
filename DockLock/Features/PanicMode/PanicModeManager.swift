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

    private var hiddenApps: [NSRunningApplication] = []
    private var isAuthenticating = false
    private var panicCancellables = Set<AnyCancellable>()
    private var shortcutMonitor: Any?
    private var appSwitchMonitor: Any?
    private let blocklist = AppBlocklist.shared
    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

    // One black overlay per screen — covers full-screen panic apps on all displays.
    // Keyed by CGDirectDisplayID so we can reuse windows across show/hide cycles.
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

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
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.animationBehavior = .none

        // Blur + darken whatever is on screen rather than covering with solid black.
        // NSVisualEffectView with .behindWindow blending blurs content rendered below
        // this window in the compositor. .hudWindow on darkAqua appearance gives a
        // heavy dark blur that makes underlying content unreadable.
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

    /// Pre-warms overlay windows for every connected screen.
    /// Creates the NSWindow + NSVisualEffectView and orders them front at alphaValue=0
    /// so the GPU initialises the blur pipeline immediately. Subsequent show/hide is
    /// then just an alphaValue flip — no window-creation or blur warm-up delay.
    private func prewarmOverlays() {
        for screen in NSScreen.screens {
            let win = overlayWindow(for: screen)
            win.alphaValue = 0
            win.orderFrontRegardless()
        }
    }

    /// Shows overlays only on the given screens; hides overlays on all others.
    private func showOverlays(on screens: [NSScreen]) {
        let targetIDs = Set(screens.map { $0.displayID })
        for screen in screens {
            overlayWindow(for: screen).alphaValue = 1
        }
        for (id, win) in overlayWindows where !targetIDs.contains(id) {
            win.alphaValue = 0
        }
    }

    private func showOverlaysOnAllScreens() {
        for screen in NSScreen.screens {
            overlayWindow(for: screen).alphaValue = 1
        }
    }

    private func hideAllOverlays() {
        overlayWindows.values.forEach { $0.alphaValue = 0 }
    }

    private func dismissAllOverlays() {
        overlayWindows.values.forEach { $0.orderOut(nil) }
    }

    /// Returns the NSScreens that currently have an on-screen window belonging to a blocklisted app.
    ///
    /// Called only when a blocklisted app is frontmost (i.e. hide() silently failed — full-screen
    /// case). At that point the app IS visible so CGWindowList will find its window.
    /// For windowed apps where hide() succeeded the windows are off-screen and this returns [],
    /// which correctly causes all overlays to be hidden.
    private func screensContainingBlocklistedWindows() -> [NSScreen] {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let blockedPIDs = Set(hiddenApps.compactMap { app -> pid_t? in
            let pid = app.processIdentifier
            return pid == 0 ? nil : pid
        })
        guard !blockedPIDs.isEmpty else { return [] }

        // Collect on-screen window rects (CG coordinates) for blocklisted PIDs.
        // kCGWindowBounds values come back as NSNumber — cast to NSDictionary, not [String: CGFloat].
        var windowRects: [CGRect] = []
        for info in list {
            guard let pidValue = info[kCGWindowOwnerPID as String] as? Int,
                  blockedPIDs.contains(pid_t(pidValue)),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            var rect = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(boundsDict, &rect)
            if !rect.isEmpty { windowRects.append(rect) }
        }
        guard !windowRects.isEmpty else { return [] }

        // Coordinate systems:
        //   CGWindowList  — origin at TOP-LEFT of the primary (menu-bar) screen, Y increases DOWN.
        //   NSScreen.frame — origin at BOTTOM-LEFT of the primary screen, Y increases UP.
        //
        // Conversion (AppKit → CG):
        //   cgY = primaryScreen.frame.maxY - appKitRect.maxY
        //
        // Using primaryScreen.frame.maxY (the primary screen's height, since its origin is y=0)
        // as the reference — NOT the tallest screen's maxY, which would shift shorter screens down.
        let mainMaxY = NSScreen.main?.frame.maxY ?? 0

        return NSScreen.screens.filter { screen in
            let cgFrame = CGRect(
                x: screen.frame.minX,
                y: mainMaxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            return windowRects.contains { $0.intersects(cgFrame) }
        }
    }

    private init() {
        settings.$panicShortcutEnabled
            .sink { [weak self] (enabled: Bool) in
                if enabled { self?.registerShortcut() } else { self?.unregisterShortcut() }
            }
            .store(in: &cancellables)

        // Hide apps that launch into the blocklist while panic is active
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { [weak self] app in
                guard let self, self.isActive else { return false }
                return app.bundleIdentifier.map { self.blocklist.bundleIDs.contains($0) } ?? false
            }
            .sink { [weak self] app in
                app.hide()
                if !(self?.hiddenApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) ?? false) {
                    self?.hiddenApps.append(app)
                }
            }
            .store(in: &cancellables)

        // Clear panic state on screen lock — user must re-login anyway
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
        // Only record a manual panic event — proximity lock records its own event.
        if !isActive {
            LockHistoryStore.shared.record(.panic)
        }
        // Close Notification Center so blocklisted app widgets are not exposed.
        closeNotificationCenter()
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return blocklist.bundleIDs.contains(id) && $0.activationPolicy == .regular
        }
        // Attempt to hide all blocklisted apps. For windowed apps this works immediately.
        // For full-screen apps hide() silently fails — the overlay catches those below.
        hiddenApps.forEach { $0.hide() }
        isActive = true
        // Pre-warm blur overlays now so the GPU has the blur pipeline ready.
        // When a full-screen app needs coverage or a window-switch flash needs suppressing,
        // showing the overlay is then an instant alphaValue flip rather than a cold render.
        prewarmOverlays()
        startMonitoringSpaceSwitches()
    }

    // MARK: - Notification Center

    /// Closes Notification Center so widgets from blocklisted apps are not visible.
    /// Uses two strategies: hide the NC process, then send Escape to dismiss the
    /// transient panel — without moving the cursor.
    private func closeNotificationCenter() {
        // Strategy 1: hide the Notification Center process.
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .forEach { $0.hide() }

        // Strategy 2: send Escape to dismiss the NC transient NSPanel.
        // A keyboard event does not move the cursor, unlike a simulated mouse click.
        // keyCode 0x35 = Escape.
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Space Switch Monitoring

    private func startMonitoringSpaceSwitches() {
        let center = NSWorkspace.shared.notificationCenter

        // PROACTIVE: cover the screen before any transition animation starts.
        //
        // didDeactivateApplicationNotification fires the instant the current app loses
        // focus — before the next app's window begins to appear. We show blur on all
        // screens here so there is no gap between "app A gone" and "overlay visible".
        center.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.isAuthenticating,
                      !self.hiddenApps.isEmpty else { return }
                self.showOverlaysOnAllScreens()
            }
            .store(in: &panicCancellables)

        // ⌘Tab global monitor: show blur the moment the user presses ⌘Tab so the
        // App Switcher overlay itself is blurred and the selected app can't flash.
        appSwitchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, !self.isAuthenticating,
                  !self.hiddenApps.isEmpty else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.keyCode == 48 /* Tab */ else { return }
            self.showOverlaysOnAllScreens()
        }

        // ⌘Tab / clicking a Dock icon unhides the app BEFORE activating it.
        // Re-hide immediately at the unhide step as a further safeguard.
        center.publisher(for: NSWorkspace.didUnhideApplicationNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { [weak self] app in self?.isBlocklisted(app) ?? false }
            .sink { app in app.hide() }
            .store(in: &panicCancellables)

        // didActivateApplicationNotification: re-evaluate once the new app is settled.
        // Hides the preemptive overlay if the new frontmost app is not blocklisted.
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in self?.updateBlurOverlay(for: app) }
            .store(in: &panicCancellables)

        // Fallback: activeSpaceDidChangeNotification with a short delay so that
        // frontmostApplication has time to settle after the Space transition.
        center.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.isActive else { return }
                    if let front = NSWorkspace.shared.frontmostApplication {
                        self.updateBlurOverlay(for: front)
                    }
                }
            }
            .store(in: &panicCancellables)
    }

    private func isBlocklisted(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map { blocklist.bundleIDs.contains($0) } ?? false
    }

    private func updateBlurOverlay(for app: NSRunningApplication) {
        guard isActive else {
            hideAllOverlays()
            return
        }
        // Keep overlay visible while Touch ID / password prompt is showing.
        if isAuthenticating { return }

        if isBlocklisted(app) {
            // Re-apply hide() so the app doesn't flash during window switches (⌘Tab, Mission Control).
            // No-op for windowed apps that are already hidden; catches full-screen apps where
            // hide() silently fails.
            app.hide()
        }

        // Always recalculate from the live window list.
        // • Windowed apps hidden by hide() disappear from CGWindowList → screens = [] → overlays hidden.
        //   This prevents the overlay bleeding into other Spaces/Desktops where no blocklisted app lives.
        // • Full-screen apps that resisted hide() remain visible → screens = [correct screen] → overlay
        //   shown only on that screen.
        // No fallback to "all screens": if nothing is detectable we show nothing, avoiding false
        // positives on Desktops that have no blocklisted app open.
        let screens = screensContainingBlocklistedWindows()
        if screens.isEmpty {
            hideAllOverlays()
        } else {
            showOverlays(on: screens)
        }
    }

    // MARK: - Release

    func releasePanic() {
        guard isActive else { return }
        if settings.panicRequiresTouchID {
            // Show overlays on all screens immediately so blocklisted apps stay
            // hidden behind the Touch ID dialog while auth is in progress.
            isAuthenticating = true
            showOverlaysOnAllScreens()

            authenticateWithBiometrics { [weak self] success in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unhideAll()
                } else {
                    // Auth cancelled/failed — re-evaluate based on current frontmost app
                    if let front = NSWorkspace.shared.frontmostApplication {
                        self.updateBlurOverlay(for: front)
                    }
                }
            }
        } else {
            unhideAll()
        }
    }

    private func unhideAll() {
        hiddenApps.forEach { $0.unhide() }
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        stopAppSwitchMonitor()
        dismissAllOverlays()
        isActive = false
    }

    /// Resets panic state without unhiding (used when screen locks — apps are hidden by OS anyway).
    private func clearWithoutUnhiding() {
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        stopAppSwitchMonitor()
        dismissAllOverlays()
        isActive = false
    }

    private func stopAppSwitchMonitor() {
        if let monitor = appSwitchMonitor {
            NSEvent.removeMonitor(monitor)
            appSwitchMonitor = nil
        }
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @MainActor @escaping (Bool) -> Void) {
        let context = LAContext()
        // Use .deviceOwnerAuthentication (Touch ID + password in one system dialog managed by
        // SecurityAgent). Using .deviceOwnerAuthenticationWithBiometrics causes "Use Password"
        // to return LAError.userFallback to the app instead of handling it internally — the app
        // would need to present its own password UI. With .deviceOwnerAuthentication the system
        // handles the entire flow and the dialog appears above our overlay window.
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Unlock DockLock Panic Mode") { success, authError in
            Task { @MainActor in
                if !success, let err = authError as? LAError, err.code == .authenticationFailed {
                    // Wrong biometric or wrong password — capture the intruder.
                    IntruderCaptureManager.shared.capturePhoto { filename in
                        LockHistoryStore.shared.record(.intruderCapture, photoFilename: filename)
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
