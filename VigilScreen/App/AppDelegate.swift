import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var menuBarManager: MenuBarManager?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        menuBarManager = MenuBarManager()
        menuBarManager?.setup()

        if !PermissionManager.shared.hasAccessibilityPermission {
            showAccessibilityAlert()
        }

        _ = PanicModeManager.shared
        _ = LockTrigger.shared
        _ = ShoulderSurfingDetector.shared

        CloudSyncStore.shared.synchronize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Accessibility permission

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Vigil Screen needs Accessibility access to register the ⌘⇧L global shortcut.\n\nClick \"Open Settings\", find Vigil Screen in the list, and turn it on."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionManager.shared.requestAccessibilityIfNeeded()
        }
    }

    // MARK: - Settings window

    func openSettings() {
        // Close the popover first — it holds the key window and will block
        // the settings window from becoming visible if still open.
        menuBarManager?.closePopover()

        // Wait one run loop after the popover dismisses, then show the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.showSettingsWindow()
        }
    }

    private func showSettingsWindow() {
        // Switch to .regular so the window receives focus immediately.
        // .accessory apps don't become key by default, causing ~10 s input delay.
        NSApp.setActivationPolicy(.regular)

        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vigil Screen Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        window.setFrameAutosaveName("VigilScreenSettings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
            // Revert to accessory so the Dock icon disappears when settings is closed.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
