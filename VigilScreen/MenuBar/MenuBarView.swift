import SwiftUI

struct MenuBarView: View {
    @AppStorage("hasShownWelcome") private var hasShownWelcome = false
    @ObservedObject private var panicManager = PanicModeManager.shared
    @ObservedObject private var trigger = LockTrigger.shared
    @ObservedObject private var monitor = BluetoothMonitor.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        if !hasShownWelcome {
            WelcomeView()
        } else {
            mainView
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panicButton
            if settings.proximityLockEnabled {
                Divider()
                proximityRow
            }
            Divider()
            footer
        }
        .frame(width: 256)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(panicManager.isActive ? .red : .accentColor)
            Text("Vigil Screen")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var panicButton: some View {
        let active = panicManager.isActive
        let color: Color = active ? .green : .red

        let buttonLabel = HStack(spacing: 0) {
            Label(
                active ? "Release" : "Panic Mode",
                systemImage: active ? "eye" : "exclamationmark.shield.fill"
            )
            .fontWeight(.semibold)
            Spacer()
            Text("⌘⇧L")
                .font(.caption)
                .fontWeight(.medium)
                .opacity(0.65)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)

        return Group {
            if #available(macOS 26, *) {
                Button { active ? panicManager.releasePanic() : panicManager.triggerPanic() } label: {
                    buttonLabel.foregroundColor(active ? .green : .white)
                }
                .glassEffect(
                    .regular.tint(color).interactive(),
                    in: .rect(cornerRadius: 8)
                )
                .buttonStyle(.plain)
            } else {
                Button { active ? panicManager.releasePanic() : panicManager.triggerPanic() } label: {
                    buttonLabel
                        .background(color.opacity(active ? 0.18 : 0.85))
                        .foregroundColor(active ? color : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var proximityRow: some View {
        ProximityStatusRow(
            monitor: monitor,
            trigger: trigger,
            threshold: Int(settings.proximityRSSIThreshold)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button {
                AppDelegate.shared?.openSettings()
            } label: {
                Label("Settings", systemImage: "gear")
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
