import AppKit
import LocalAuthentication
import Combine

@MainActor
class PanicModeManager: ObservableObject {
    static let shared = PanicModeManager()

    @Published private(set) var isActive = false

    private var hiddenApps: [NSRunningApplication] = []
    private var isAuthenticating = false
    private var panicCancellables = Set<AnyCancellable>()
    private var shortcutMonitor: Any?
    private let blocklist = AppBlocklist.shared
    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

    // Black overlay shown over full-screen panic apps (where hide() silently fails)
    // when the user switches to their Space.
    private lazy var blurOverlayWindow: NSWindow = {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .black
        win.isOpaque = true
        win.level = .screenSaver
        // .fullScreenAuxiliary lets the window appear on full-screen app Spaces
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.animationBehavior = .none
        return win
    }()

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
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return blocklist.bundleIDs.contains(id) && $0.activationPolicy == .regular
        }
        // Attempt to hide all blocklisted apps. For windowed apps this works immediately.
        // For full-screen apps hide() silently fails — the overlay catches those below.
        hiddenApps.forEach { $0.hide() }
        isActive = true
        startMonitoringSpaceSwitches()
    }

    // MARK: - Space Switch Monitoring

    private func startMonitoringSpaceSwitches() {
        let center = NSWorkspace.shared.notificationCenter

        // didActivateApplicationNotification carries the newly active app in userInfo —
        // more reliable than reading frontmostApplication from activeSpaceDidChangeNotification,
        // which fires before the frontmost app property updates.
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
            blurOverlayWindow.orderOut(nil)
            return
        }
        // Keep overlay visible while Touch ID / password prompt is showing.
        if isAuthenticating { return }
        // Show overlay whenever a blocklisted app is frontmost.
        // If hide() succeeded (windowed app), it can never become frontmost, so this
        // only fires for full-screen apps where hide() silently failed.
        if isBlocklisted(app) {
            if let screen = NSScreen.main {
                blurOverlayWindow.setFrame(screen.frame, display: false)
            }
            blurOverlayWindow.orderFrontRegardless()
        } else {
            blurOverlayWindow.orderOut(nil)
        }
    }

    // MARK: - Release

    func releasePanic() {
        guard isActive else { return }
        if settings.panicRequiresTouchID {
            // Show overlay immediately so blocklisted apps stay hidden
            // behind the Touch ID dialog while auth is in progress.
            isAuthenticating = true
            if let screen = NSScreen.main {
                blurOverlayWindow.setFrame(screen.frame, display: false)
            }
            blurOverlayWindow.orderFrontRegardless()

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
        blurOverlayWindow.orderOut(nil)
        isActive = false
    }

    /// Resets panic state without unhiding (used when screen locks — apps are hidden by OS anyway).
    private func clearWithoutUnhiding() {
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        blurOverlayWindow.orderOut(nil)
        isActive = false
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @MainActor @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock DockLock Panic Mode") { success, _ in
                Task { @MainActor in completion(success) }
            }
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock DockLock Panic Mode"
        ) { success, _ in
            Task { @MainActor in completion(success) }
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
