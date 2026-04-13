import Foundation
import CoreBluetooth
import Combine

class BluetoothMonitor: NSObject, ObservableObject {
    static let shared = BluetoothMonitor()

    // MARK: - Published state

    @Published var bluetoothState: CBManagerState = .unknown
    /// Only true during the user-facing discovery scan (15 s window).
    @Published var isScanning = false
    /// Devices found during a discovery scan (named only, sorted by RSSI).
    @Published var nearbyDevices: [DiscoveredDevice] = []

    @Published private(set) var pairedDeviceUUID: UUID?
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var currentRSSI: Int = 0
    @Published private(set) var isDeviceVisible: Bool = false

    // MARK: - Private

    private var centralManager: CBCentralManager!
    private var lastSeenDate: Date?
    private var presenceTimer: Timer?
    private var discoveryScanTimer: Timer?

    /// Seconds of BLE silence before declaring the device gone.
    /// iPhones advertise every ~1 s when screen is on; 8 s is generous but avoids false positives.
    private let silenceTimeout: TimeInterval = 8

    private override init() {
        super.init()
        // No options — CBCentralManagerOptionRestoreIdentifierKey is iOS-only
        // and causes .unsupported state on macOS.
        centralManager = CBCentralManager(delegate: self, queue: .main)
        loadPairedDevice()
    }

    // MARK: - Discovery scan (user-initiated, 15 s, resets device list)

    func startDiscoveryScan() {
        guard centralManager.state == .poweredOn else { return }
        nearbyDevices = []
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        discoveryScanTimer?.invalidate()
        discoveryScanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.stopDiscoveryScan()
        }
    }

    func stopDiscoveryScan() {
        discoveryScanTimer?.invalidate()
        isScanning = false
        // Keep the underlying BT scan running if a device is paired (monitoring mode).
        if pairedDeviceUUID == nil {
            centralManager.stopScan()
        }
    }

    // MARK: - Monitoring scan (background, continuous, no device list reset)

    func startMonitoringScan() {
        guard pairedDeviceUUID != nil, centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: - Pairing

    func pair(device: DiscoveredDevice) {
        pairedDeviceUUID = device.uuid
        pairedDeviceName = device.name
        KeychainHelper.save(key: "pairedUUID", value: device.uuid.uuidString)
        KeychainHelper.save(key: "pairedName", value: device.name)
        startPresenceTimer()
        // Stop discovery scan before switching to monitoring to avoid overlapping scans.
        stopDiscoveryScan()
        startMonitoringScan()
    }

    func unpair() {
        pairedDeviceUUID = nil
        pairedDeviceName = nil
        currentRSSI = 0
        isDeviceVisible = false
        lastSeenDate = nil
        stopPresenceTimer()
        KeychainHelper.delete(key: "pairedUUID")
        KeychainHelper.delete(key: "pairedName")
        centralManager.stopScan()
        isScanning = false
    }

    // MARK: - Presence timer

    func startPresenceTimer() {
        stopPresenceTimer()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkPresence()
        }
    }

    func stopPresenceTimer() {
        presenceTimer?.invalidate()
        presenceTimer = nil
        isDeviceVisible = false
    }

    private func checkPresence() {
        guard let last = lastSeenDate else {
            // Never seen — still in initial startup; don't flip to "missing"
            return
        }
        isDeviceVisible = Date().timeIntervalSince(last) < silenceTimeout
    }

    // MARK: - Persistence

    private func loadPairedDevice() {
        guard let uuidString = KeychainHelper.load(key: "pairedUUID"),
              let uuid = UUID(uuidString: uuidString) else { return }
        pairedDeviceUUID = uuid
        pairedDeviceName = KeychainHelper.load(key: "pairedName")
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn, pairedDeviceUUID != nil {
            startMonitoringScan()
            startPresenceTimer()
        } else if central.state != .poweredOn {
            isScanning = false
            isDeviceVisible = false
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        // CoreBluetooth returns 127 when RSSI is unreadable
        guard rssi != 127 else { return }

        // Track paired device
        if let pairedUUID = pairedDeviceUUID, peripheral.identifier == pairedUUID {
            currentRSSI = rssi
            lastSeenDate = Date()
            isDeviceVisible = true
        }

        // Update discovery list (named devices only)
        guard let name = peripheral.name
                ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              !name.isEmpty else { return }

        let device = DiscoveredDevice(uuid: peripheral.identifier, name: name, rssi: rssi)
        if let idx = nearbyDevices.firstIndex(where: { $0.uuid == device.uuid }) {
            nearbyDevices[idx] = device
        } else {
            nearbyDevices.append(device)
        }
        nearbyDevices.sort { $0.rssi > $1.rssi }
    }

}

// MARK: - DiscoveredDevice

struct DiscoveredDevice: Identifiable, Equatable {
    let id = UUID()
    let uuid: UUID
    let name: String
    let rssi: Int

    var signalDescription: String {
        if rssi >= -60 { return "Excellent" }
        if rssi >= -70 { return "Good" }
        if rssi >= -80 { return "Fair" }
        return "Weak"
    }
}

// MARK: - KeychainHelper

enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[DockLock] Keychain save failed for key '\(key)': OSStatus \(status)")
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[DockLock] Keychain delete failed for key '\(key)': OSStatus \(status)")
        }
    }
}
