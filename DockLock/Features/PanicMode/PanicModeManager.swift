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
        win.backgroundColor = .black
        win.isOpaque = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.animationBehavior = .none
        overlayWindows[displayID] = win
        return win
    }

    /// Shows overlays only on screens that currently have a window belonging to a blocklisted app.
    /// Falls back to all screens when no specific screens can be identified (e.g. full-screen space).
    private func showOverlaysForBlocklistedApps() {
        let screens = screensContainingBlocklistedWindows()
        let targets = screens.isEmpty ? NSScreen.screens : screens
        for screen in targets {
            overlayWindow(for: screen).orderFrontRegardless()
        }
        // Hide overlays on screens that no longer need coverage.
        for screen in NSScreen.screens where !targets.contains(screen) {
            overlayWindows[screen.displayID]?.orderOut(nil)
        }
    }

    private func showOverlaysOnAllScreens() {
        for screen in NSScreen.screens {
            overlayWindow(for: screen).orderFrontRegardless()
        }
    }

    private func hideAllOverlays() {
        overlayWindows.values.forEach { $0.orderOut(nil) }
    }

    /// Returns the set of NSScreens that contain at least one window belonging to a blocklisted app.
    private func screensContainingBlocklistedWindows() -> [NSScreen] {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Build a set of PIDs for running hidden apps (they may still have windows on screen
        // for a brief moment) plus any blocklisted apps that are frontmost (full-screen case).
        let blockedPIDs = Set(
            hiddenApps.compactMap { $0.processIdentifier == 0 ? nil : $0.processIdentifier }
        )
        guard !blockedPIDs.isEmpty else { return [] }

        // Collect CGRects of windows owned by blocklisted PIDs.
        var windowRects: [CGRect] = []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  blockedPIDs.contains(pid),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            var rect = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect)
            if !rect.isEmpty { windowRects.append(rect) }
        }

        guard !windowRects.isEmpty else { return [] }

        // Map each window rect to the NSScreen it belongs to.
        // NSScreen uses flipped coordinates (origin at top-left of menu-bar screen),
        // while CGWindowListCopyWindowInfo uses CG coordinates (origin at bottom-left).
        // Convert by flipping the Y axis against the full virtual desktop height.
        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        var result: [NSScreen] = []
        for screen in NSScreen.screens {
            // Convert NSScreen frame (AppKit) to CG coordinates for comparison.
            let cgScreenFrame = CGRect(
                x: screen.frame.minX,
                y: totalHeight - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if windowRects.contains(where: { $0.intersects(cgScreenFrame) }) {
                result.append(screen)
            }
        }
        return result
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
        startMonitoringSpaceSwitches()
    }

    // MARK: - Notification Center

    /// Closes Notification Center so widgets from blocklisted apps are not visible.
    /// Uses two strategies: hide the NC process, then simulate a background click
    /// to dismiss the transient panel if it's still showing.
    private func closeNotificationCenter() {
        // Strategy 1: hide the Notification Center process
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .forEach { $0.hide() }

        // Strategy 2: simulate a click at the top-left of the main screen.
        // NC is a transient NSPanel — it dismisses on any outside click.
        // Top-left is safe (no UI elements there) and far from NC (which opens on the right).
        guard let src = CGEventSource(stateID: .hidSystemState),
              let screen = NSScreen.main else { return }
        let point = CGPoint(x: screen.frame.minX + 10, y: screen.frame.minY + 10)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cgSessionEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cgSessionEventTap)
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
            hideAllOverlays()
            return
        }
        // Keep overlay visible while Touch ID / password prompt is showing.
        if isAuthenticating { return }

        if isBlocklisted(app) {
            // Bug fix: re-apply hide() so the app doesn't flash during window switches.
            // For windowed apps hide() already worked, this is a no-op. For full-screen
            // apps where hide() silently fails, the overlay below catches it.
            app.hide()
            // Show overlays only on screens that contain this app's windows.
            showOverlaysForBlocklistedApps()
        } else {
            // Recalculate — other blocklisted apps may still have windows on some screens.
            let screens = screensContainingBlocklistedWindows()
            if screens.isEmpty {
                hideAllOverlays()
            } else {
                for screen in screens {
                    overlayWindow(for: screen).orderFrontRegardless()
                }
                for screen in NSScreen.screens where !screens.contains(screen) {
                    overlayWindows[screen.displayID]?.orderOut(nil)
                }
            }
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
        hideAllOverlays()
        isActive = false
    }

    /// Resets panic state without unhiding (used when screen locks — apps are hidden by OS anyway).
    private func clearWithoutUnhiding() {
        hiddenApps = []
        isAuthenticating = false
        panicCancellables.removeAll()
        hideAllOverlays()
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
