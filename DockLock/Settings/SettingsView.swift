import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink(destination: GeneralSettingsView()) {
                    Label("General", systemImage: "gear")
                }
                NavigationLink(destination: PanicModeView()) {
                    Label("Panic Mode", systemImage: "eye.slash")
                }
                NavigationLink(destination: ProximityView()) {
                    Label("Proximity Lock", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink(destination: LockHistoryView()) {
                    Label("History", systemImage: "clock")
                }
            }
            .navigationTitle("DockLock")
            .listStyle(.sidebar)
        } detail: {
            GeneralSettingsView()
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        toggleLaunchAtLogin(enabled)
                    }
            }

            Section("Permissions") {
                HStack {
                    Label("Accessibility", systemImage: "accessibility")
                    Spacer()
                    if permissions.hasAccessibilityPermission {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        Button("Grant Access") {
                            permissions.requestAccessibilityIfNeeded()
                        }
                    }
                }
            }

            Section("About") {
                if let privacyURL = URL(string: "https://github.com/atomsbaza/DockLock#privacy") {
                    Link(destination: privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
                if let issuesURL = URL(string: "https://github.com/atomsbaza/DockLock/issues") {
                    Link(destination: issuesURL) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settings.launchAtLogin = !enable // revert on failure
        }
    }
}
