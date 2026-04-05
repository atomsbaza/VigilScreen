import AppKit
import LocalAuthentication
import Combine

class PanicModeManager: ObservableObject {
    static let shared = PanicModeManager()

    @Published private(set) var isActive = false

    private var hiddenApps: [NSRunningApplication] = []
    private var shortcutMonitor: Any?
    private let blocklist = AppBlocklist.shared
    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

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
            .sink { [weak self] _ in
                // Apps are already hidden by the lock screen; reset tracked state
                self?.clearWithoutUnhiding()
            }
            .store(in: &cancellables)
    }

    // MARK: - Panic

    func triggerPanic() {
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return blocklist.bundleIDs.contains(id) && $0.activationPolicy == .regular
        }
        hiddenApps.forEach { exitFullScreenIfNeeded($0) }
        isActive = true
    }

    // MARK: - Full screen handling

    /// Exits full screen via Accessibility API then hides the app.
    /// Regular (non-full-screen) apps are hidden immediately.
    private func exitFullScreenIfNeeded(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted() else {
            app.hide()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Set a timeout so AX calls don't hang if the app is unresponsive
        AXUIElementSetMessagingTimeout(axApp, 2.0)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let cfArray = windowsRef,
              CFGetTypeID(cfArray) == CFArrayGetTypeID() else {
            app.hide()
            return
        }

        let windowsArray = cfArray as! CFArray
        let count = CFArrayGetCount(windowsArray)

        var wasFullScreen = false
        for i in 0 ..< count {
            let rawWindow = CFArrayGetValueAtIndex(windowsArray, i)
            let window = unsafeBitCast(rawWindow, to: AXUIElement.self)

            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &valueRef) == .success,
                  let value = valueRef,
                  CFGetTypeID(value) == CFBooleanGetTypeID(),
                  CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) else { continue }

            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            wasFullScreen = true
        }

        if wasFullScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard !app.isTerminated else { return }
                app.hide()
            }
        } else {
            app.hide()
        }
    }

    func releasePanic() {
        guard isActive else { return }
        if settings.panicRequiresTouchID {
            authenticateWithBiometrics { [weak self] success in
                if success { self?.unhideAll() }
            }
        } else {
            unhideAll()
        }
    }

    private func unhideAll() {
        hiddenApps.forEach { $0.unhide() }
        hiddenApps = []
        isActive = false
    }

    /// Resets panic state without unhiding (used when screen locks — apps are hidden by OS anyway).
    private func clearWithoutUnhiding() {
        hiddenApps = []
        isActive = false
    }

    // MARK: - Biometrics

    private func authenticateWithBiometrics(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock DockLock Panic Mode") { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock DockLock Panic Mode"
        ) { success, _ in
            DispatchQueue.main.async { completion(success) }
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

    deinit { unregisterShortcut() }
}
