import SwiftUI

@main
struct VigilScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window scenes — this is a menu bar only app.
        // The settings window is managed manually by AppDelegate.openSettings().
        Settings { EmptyView() }
    }
}
