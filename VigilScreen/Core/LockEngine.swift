import Foundation
import AppKit

struct LockEngine {
    /// Locks the screen. Tries CGSession first, falls back to screensaver activation.
    static func lockScreen() {
        if tryCGSession() { return }
        // Fallback: activate screensaver (also locks if "Require password immediately" is set).
        // Note: NSWorkspace.open is asynchronous — lock is best-effort with no completion callback.
        let screensaverURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        guard FileManager.default.fileExists(atPath: screensaverURL.path) else {
            print("[VigilScreen] LockEngine: screensaver fallback unavailable — CGSession and ScreenSaverEngine both missing")
            return
        }
        NSWorkspace.shared.open(screensaverURL)
    }

    @discardableResult
    private static func tryCGSession() -> Bool {
        let candidates = [
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
            // Alternate location on some macOS versions
            "/usr/bin/CGSession",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["-suspend"]
            do {
                try task.run()
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
