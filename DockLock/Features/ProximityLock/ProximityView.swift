import SwiftUI
import CoreBluetooth

struct ProximityView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var monitor = BluetoothMonitor.shared
    @ObservedObject private var trigger = LockTrigger.shared

    var body: some View {
        Form {
            enableSection
            if settings.proximityLockEnabled {
                btWarningSection
                pairedDeviceSection
                tuningSection
                liveStatusSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Proximity Lock")
    }

    // MARK: - Sections

    @ViewBuilder private var enableSection: some View {
        Section {
            Toggle("Enable Proximity Lock", isOn: $settings.proximityLockEnabled)
        } footer: {
            Text("Locks your screen when your paired device leaves Bluetooth range.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var btWarningSection: some View {
        // .unknown = still initializing, don't warn yet
        if monitor.bluetoothState != .poweredOn, monitor.bluetoothState != .unknown {
            Section {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(bluetoothStateMessage)
                }
            }
        }
    }

    @ViewBuilder private var pairedDeviceSection: some View {
        Section("Paired Device") {
            if let name = monitor.pairedDeviceName {
                PairedDeviceRow(name: name, rssi: monitor.currentRSSI, isVisible: monitor.isDeviceVisible)
                Button("Unpair", role: .destructive) { monitor.unpair() }
            } else {
                ScanSection()
            }
        }
    }

    @ViewBuilder private var tuningSection: some View {
        Section {
            HStack {
                Text("Lock delay")
                Spacer()
                Slider(value: $settings.proximityLockDelay, in: 5...30, step: 1)
                    .frame(width: 160)
                Text("\(Int(settings.proximityLockDelay))s")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("Signal threshold")
                Spacer()
                Slider(value: $settings.proximityRSSIThreshold, in: -90 ... -60, step: 1)
                    .frame(width: 160)
                Text("\(Int(settings.proximityRSSIThreshold)) dBm")
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        } header: {
            Text("Tuning")
        } footer: {
            Text("Lock delay: seconds of signal loss before locking. Threshold: signal strength below which the countdown starts.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var liveStatusSection: some View {
        if monitor.pairedDeviceName != nil {
            Section("Live Status") {
                HStack {
                    Label("Signal", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    RSSIBadge(rssi: monitor.currentRSSI, threshold: Int(settings.proximityRSSIThreshold))
                }
                if trigger.isCountingDown {
                    HStack {
                        Label("Locking in", systemImage: "timer")
                            .foregroundColor(.orange)
                        Spacer()
                        Text("\(trigger.secondsRemaining)s")
                            .monospacedDigit()
                            .bold()
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    private var bluetoothStateMessage: String {
        switch monitor.bluetoothState {
        case .poweredOff:   return "Bluetooth is off. Turn it on to use Proximity Lock."
        case .unauthorized: return "Bluetooth permission denied. Check System Settings → Privacy."
        case .unsupported:  return "Bluetooth is not supported on this Mac."
        default:            return "Bluetooth is unavailable."
        }
    }
}

// MARK: - Paired device row

private struct PairedDeviceRow: View {
    let name: String
    let rssi: Int
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(isVisible ? "In range" : "Out of range")
                    .font(.caption)
                    .foregroundColor(isVisible ? .green : .red)
            }
            Spacer()
            if isVisible {
                Text("\(rssi) dBm")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Scan section

private struct ScanSection: View {
    @ObservedObject private var monitor = BluetoothMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                monitor.startDiscoveryScan()
            } label: {
                HStack {
                    if monitor.isScanning { ProgressView().controlSize(.small) }
                    Text(monitor.isScanning ? "Scanning…" : "Scan for Devices")
                }
            }
            .disabled(monitor.isScanning || monitor.bluetoothState != .poweredOn)

            if !monitor.nearbyDevices.isEmpty {
                Divider()
                ForEach(monitor.nearbyDevices) { device in
                    Button {
                        monitor.pair(device: device)
                    } label: {
                        HStack {
                            Image(systemName: "iphone").foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).fontWeight(.medium)
                                Text("\(device.rssi) dBm · \(device.signalDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            } else if monitor.isScanning {
                Text("Looking for nearby Bluetooth devices…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - RSSI badge

private struct RSSIBadge: View {
    let rssi: Int
    let threshold: Int

    private var color: Color {
        if rssi == 0        { return .secondary }
        if rssi < threshold { return .red }
        if rssi >= -60      { return .green }
        if rssi >= -70      { return .yellow }
        return .orange
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(rssi == 0 ? Color.gray : color)
                .frame(width: 8, height: 8)
            Text(rssi == 0 ? "—" : "\(rssi) dBm")
                .monospacedDigit()
                .foregroundColor(color)
        }
    }
}
