import SwiftUI

struct WelcomeView: View {
    @AppStorage("hasShownWelcome") private var hasShownWelcome = false
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var monitor = BluetoothMonitor.shared
    @ObservedObject private var safelist = AppSafelist.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            steps
            Divider()
            footer
        }
        .frame(width: 256)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Welcome to Vigil Screen")
                    .font(.headline)
                Text("Complete setup to get protected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(spacing: 0) {
            SetupStepRow(
                title: "Grant Accessibility Access",
                detail: "Enables the global ⌘⇧L panic shortcut",
                isDone: permissions.hasAccessibilityPermission
            )
            Divider().padding(.leading, 38)
            SetupStepRow(
                title: "Pair a Bluetooth Device",
                detail: "iPhone or Apple Watch for Proximity Lock",
                isDone: monitor.pairedDeviceUUID != nil
            )
            Divider().padding(.leading, 38)
            SetupStepRow(
                title: "App Safelist Ready",
                detail: "\(safelist.bundleIDs.count) apps visible by default",
                isDone: true
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if #available(macOS 26, *) {
                Button("Open Settings") {
                    hasShownWelcome = true
                    AppDelegate.shared?.openSettings()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            } else {
                Button("Open Settings") {
                    hasShownWelcome = true
                    AppDelegate.shared?.openSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Spacer()

            Button("Dismiss") {
                hasShownWelcome = true
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Step row

private struct SetupStepRow: View {
    let title: String
    let detail: String
    let isDone: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isDone ? .green : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .fontWeight(isDone ? .regular : .medium)
                    .foregroundColor(isDone ? .secondary : .primary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
