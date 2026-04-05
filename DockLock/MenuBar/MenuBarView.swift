import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var panicManager = PanicModeManager.shared
    @ObservedObject private var trigger = LockTrigger.shared
    @ObservedObject private var monitor = BluetoothMonitor.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(panicManager.isActive ? .red : .accentColor)
                Text("DockLock")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Panic Mode button
            Button {
                if panicManager.isActive { panicManager.releasePanic() } else { panicManager.triggerPanic() }
            } label: {
                Label(
                    panicManager.isActive ? "Release Panic Mode" : "Panic Mode",
                    systemImage: panicManager.isActive ? "eye" : "eye.slash"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(panicManager.isActive ? .green : .red)

            // Proximity Lock status
            if settings.proximityLockEnabled {
                Divider()
                ProximityStatusRow(
                    monitor: monitor,
                    trigger: trigger,
                    threshold: Int(settings.proximityRSSIThreshold)
                )
            }

            Divider()

            // Footer
            HStack {
                Button {
                    AppDelegate.shared?.openSettings()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding()
        .frame(width: 280)
    }
}

// MARK: - Proximity status row

private struct ProximityStatusRow: View {
    let monitor: BluetoothMonitor
    let trigger: LockTrigger
    let threshold: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: proximityIcon)
                .foregroundColor(proximityColor)
                .frame(width: 16)

            if trigger.isCountingDown {
                Text("Locking in \(trigger.secondsRemaining)s")
                    .foregroundColor(.orange)
                    .bold()
            } else if let name = monitor.pairedDeviceName {
                Text(monitor.isDeviceVisible ? name : "\(name) — out of range")
                    .foregroundColor(monitor.isDeviceVisible ? .primary : .secondary)
            } else {
                Button {
                    AppDelegate.shared?.openSettings()
                } label: {
                    Text("No device paired — tap to set up")
                        .foregroundStyle(.secondary)
                        .underline()
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if monitor.isDeviceVisible, monitor.currentRSSI != 0 {
                Text("\(monitor.currentRSSI) dBm")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var proximityIcon: String {
        if trigger.isCountingDown { return "timer" }
        if monitor.pairedDeviceName == nil { return "antenna.radiowaves.left.and.right.slash" }
        return monitor.isDeviceVisible
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
    }

    private var proximityColor: Color {
        if trigger.isCountingDown { return .orange }
        if !monitor.isDeviceVisible && monitor.pairedDeviceName != nil { return .red }
        return .green
    }
}
