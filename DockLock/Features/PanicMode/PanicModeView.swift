import SwiftUI
import AppKit

struct PanicModeView: View {
    @ObservedObject private var blocklist = AppBlocklist.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var manager = PanicModeManager.shared
    @State private var showAppPicker = false
    @State private var newBundleID = ""

    /// Apps known to provide Notification Center widgets.
    private let widgetApps: Set<String> = [
        "com.apple.iCal",           // Calendar
        "com.apple.Notes",          // Notes
        "com.apple.reminders",      // Reminders
        "com.apple.weather",        // Weather
        "com.apple.stocks",         // Stocks
        "com.fantastical3.mac",     // Fantastical
        "com.reeder.5.mac",         // Reeder
        "com.apple.news",           // News
    ]

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Require Touch ID to release", isOn: $settings.panicRequiresTouchID)
                Toggle("Enable ⌘⇧L global shortcut", isOn: $settings.panicShortcutEnabled)
            }

            // Warn if any blocklisted app is known to have Notification Center widgets
            if blocklist.bundleIDs.contains(where: { widgetApps.contains($0) }) {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("One or more blocklisted apps may have Notification Center widgets. DockLock will auto-close Notification Center when Panic Mode triggers.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                // Preview: how many apps will be hidden
                let appsToHide = NSWorkspace.shared.runningApplications.filter {
                    guard let id = $0.bundleIdentifier else { return false }
                    return blocklist.bundleIDs.contains(id) && $0.activationPolicy == .regular
                }
                if !manager.isActive && !appsToHide.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                        Text("\(appsToHide.count) app\(appsToHide.count == 1 ? "" : "s") will be hidden:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(appsToHide.compactMap { $0.localizedName }.joined(separator: ", "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Button(manager.isActive ? "Release Panic Mode" : "Trigger Panic Mode") {
                    if manager.isActive {
                        manager.releasePanic()
                    } else {
                        manager.triggerPanic()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(manager.isActive ? .green : .red)
                .frame(maxWidth: .infinity)
            } header: {
                Text("Test")
            } footer: {
                Text(manager.isActive ? "Panic Mode is active. Press Release or ⌘⇧L to restore apps." : "You can also press ⌘⇧L from anywhere.")
                    .foregroundStyle(.secondary)
            }

            Section {
                let ids = blocklist.bundleIDs.sorted()
                if ids.isEmpty {
                    Text("No apps in blocklist")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ids, id: \.self) { id in
                        BlocklistRow(bundleID: id) {
                            blocklist.remove(id)
                        }
                    }
                    .onDelete { indexSet in
                        let sorted = ids
                        indexSet.forEach { blocklist.remove(sorted[$0]) }
                    }
                }

                // Manual entry row
                HStack {
                    TextField("com.example.App", text: $newBundleID)
                        .onSubmit { addManual() }
                    Button("Add") { addManual() }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                HStack {
                    Text("App Blocklist")
                    Spacer()
                    Button {
                        blocklist.importFromFile()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Import blocklist from JSON file")

                    Button {
                        blocklist.exportToFile()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Export blocklist to JSON file")

                    Button {
                        showAppPicker = true
                    } label: {
                        Label("Add Running App", systemImage: "plus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Pick from currently running apps")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Panic Mode")
        .sheet(isPresented: $showAppPicker) {
            RunningAppPickerSheet(isPresented: $showAppPicker)
        }
    }

    private func addManual() {
        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        blocklist.add(trimmed)
        newBundleID = ""
    }
}

// MARK: - Blocklist row with app icon + name

private struct BlocklistRow: View {
    let bundleID: String
    let onRemove: () -> Void

    @State private var isHovering = false

    private var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    private var appName: String {
        runningApp?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? bundleID
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon = runningApp?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Remove from blocklist")
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Running app picker sheet

private struct RunningAppPickerSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var blocklist = AppBlocklist.shared

    private var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                app.bundleIdentifier != nil &&
                !blocklist.bundleIDs.contains(app.bundleIdentifier!)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Running Apps")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
            }
            .padding()

            Divider()

            if candidates.isEmpty {
                Text("All running apps are already in the blocklist.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates, id: \.bundleIdentifier) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.localizedName ?? "Unknown")
                            Text(app.bundleIdentifier ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") {
                            if let id = app.bundleIdentifier {
                                blocklist.add(id)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 420, height: 360)
    }
}
