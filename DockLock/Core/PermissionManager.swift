import AppKit
import Combine

@MainActor
class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var hasAccessibilityPermission: Bool = false

    private var pollTimer: Timer?
    private var pollCount = 0
    /// Stop polling after 60 attempts (60 s) to avoid running forever if the user ignores the prompt.
    private let maxPollCount = 60

    private init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func requestAccessibilityIfNeeded() {
        // Open System Settings → Privacy & Security → Accessibility directly.
        // On macOS 13+, AXIsProcessTrustedWithOptions only shows a redirect dialog;
        // opening the pane directly is more reliable.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
        startPolling()
    }

    /// Polls every second until permission is granted or maxPollCount is reached.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollCount = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollCount += 1
            let granted = AXIsProcessTrusted()
            if self.hasAccessibilityPermission != granted {
                self.hasAccessibilityPermission = granted
            }
            if granted || self.pollCount >= self.maxPollCount {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
            }
        }
    }
}
