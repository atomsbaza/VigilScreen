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

    // All apps hidden during panic (everything not in the safelist).
    // Tracked so they can be unhidden on release.
    private var hiddenApps: [NSRunningApplication] = []
    private var isAuthenticating = false
    private var panicCancellables = Set<AnyCancellable>()
    private var shortcutMonitor: Any?
    private let safelist = AppSafelist.shared
    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

    // One overlay per screen — blurs the desktop behind safe apps.
    // Keyed by CGDirectDisplayID so windows are reused across show/hide cycles.
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
        // Level -1: just below normal app windows (level 0).
        // Safe apps at level 0 float above the blur; the desktop behind is blurred.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
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

    /// Pre-warms overlay windows for every connected screen so subsequent show is
    /// an instant alphaValue flip with no blur-pipeline warmup delay.
    private func prewarmOverlays() {
        for screen in NSScreen.screens {
            let win = overlayWindow(for: screen)
            win.alphaValue = 0
            win.orderFrontRegardless()
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
        if !isActive {
            LockHistoryStore.shared.record(.panic)
        }
        closeNotificationCenter()

        // Hide ALL regular apps that are not in the safelist.
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return $0.activationPolicy == .regular && !safelist.bundleIDs.contains(id)
        }
        hiddenApps.forEach { $0.hide() }

        isActive = true
        prewarmOverlays()
        // Show overlay on all screens immediately — no polling, no flash.
        showOverlaysOnAllScreens()
        startMonitoringSpaceSwitches()
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

        // If a non-safelisted app gets unhidden by external means, re-hide it.
        center.publisher(for: NSWorkspace.didUnhideApplicationNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { [weak self] app in
                guard let self else { return false }
                return !self.isSafelisted(app) && app.activationPolicy == .regular
            }
            .sink { app in app.hide() }
            .store(in: &panicCancellables)

        // If a non-safelisted app activates, re-hide it.
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in self?.updateBlurOverlay(for: app) }
            .store(in: &panicCancellables)
    }

    private func isSafelisted(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map { safelist.bundleIDs.contains($0) } ?? false
    }

    private func updateBlurOverlay(for app: NSRunningApplication) {
        guard isActive else {
            hideAllOverlays()
            return
        }
        if isAuthenticating { return }

        // Re-hide any non-safelisted app that managed to activate.
        if !isSafelisted(app) && app.activationPolicy == .regular {
            app.hide()
        }
        // Overlay is always on during panic — nothing else needed.
    }

    // MARK: - Release

    func releasePanic() {
        guard isActive else { return }
        if settings.panicRequiresTouchID {
            isAuthenticating = true
            showOverlaysOnAllScreens()

            authenticateWithBiometrics { [weak self] success in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unhideAll()
                } else {
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
        dismissAllOverlays()
        isActive = false
    }

    private func clearWithoutUnhiding() {
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        dismissAllOverlays()
        isActive = false
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @MainActor @escaping (Bool) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Unlock DockLock Panic Mode") { success, authError in
            Task { @MainActor in
                if !success, let err = authError as? LAError, err.code == .authenticationFailed {
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
