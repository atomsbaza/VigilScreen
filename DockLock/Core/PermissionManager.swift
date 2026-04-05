import AppKit
import Combine

class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var hasAccessibilityPermission: Bool = false

    private var pollTimer: Timer?
    private init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func requestAccessibilityIfNeeded() {
        // Open System Settings → Privacy & Security → Accessibility directly.
        // On macOS 13+, AXIsProcessTrustedWithOptions only shows a redirect dialog;
        // opening the pane directly is more reliable.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startPolling()
    }

    /// Polls every second until permission is granted, then stops.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = AXIsProcessTrusted()
            if self.hasAccessibilityPermission != granted {
                self.hasAccessibilityPermission = granted
            }
            if granted {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
            }
        }
    }
}
