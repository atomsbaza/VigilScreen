import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

class AppBlocklist: ObservableObject {
    static let shared = AppBlocklist()

    @Published var bundleIDs: Set<String>

    private var cancellable: AnyCancellable?

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "panicBlocklist")
        bundleIDs = Set(saved ?? AppBlocklist.defaults)

        cancellable = $bundleIDs
            .dropFirst()
            .sink { UserDefaults.standard.set(Array($0), forKey: "panicBlocklist") }
    }

    func add(_ bundleID: String) {
        bundleIDs.insert(bundleID)
    }

    func remove(_ bundleID: String) {
        bundleIDs.remove(bundleID)
    }

    // MARK: - Export

    /// Writes the blocklist as a JSON array to a user-chosen file.
    func exportToFile() {
        let panel = NSSavePanel()
        panel.title = "Export App Blocklist"
        panel.nameFieldStringValue = "DockLock-Blocklist.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let sorted = bundleIDs.sorted()
        do {
            let data = try JSONEncoder().encode(sorted)
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert.showError("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    /// Reads a JSON array of bundle IDs and merges them into the current list.
    func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import App Blocklist"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let ids = try JSONDecoder().decode([String].self, from: data)
            let valid = ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            valid.forEach { bundleIDs.insert($0) }
        } catch {
            NSAlert.showError("Import failed: \(error.localizedDescription)")
        }
    }

    // Default apps to hide during panic
    static let defaults: [String] = [
        "com.apple.Terminal",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.tinyspeck.slackmacgap",
        "notion.id",
    ]
}

// MARK: - NSAlert helper

private extension NSAlert {
    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "DockLock"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
