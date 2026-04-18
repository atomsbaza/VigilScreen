import Foundation
import Combine

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var launchAtLogin: Bool
    @Published var panicShortcutEnabled: Bool
    @Published var panicRequiresTouchID: Bool
    @Published var proximityLockEnabled: Bool
    @Published var proximityLockDelay: Double
    @Published var proximityRSSIThreshold: Double
    @Published var showMenuBarStats: Bool
    @Published var intruderCaptureEnabled: Bool

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let d = UserDefaults.standard
        launchAtLogin            = d.bool(forKey: Keys.launchAtLogin)
        panicShortcutEnabled     = d.object(forKey: Keys.panicShortcutEnabled)     as? Bool   ?? true
        panicRequiresTouchID     = d.object(forKey: Keys.panicRequiresTouchID)     as? Bool   ?? true
        proximityLockEnabled     = d.bool(forKey: Keys.proximityLockEnabled)
        proximityLockDelay       = d.object(forKey: Keys.proximityLockDelay)       as? Double ?? 10.0
        proximityRSSIThreshold   = d.object(forKey: Keys.proximityRSSIThreshold)   as? Double ?? -75.0
        showMenuBarStats         = d.object(forKey: Keys.showMenuBarStats)         as? Bool   ?? false
        intruderCaptureEnabled   = d.object(forKey: Keys.intruderCaptureEnabled)   as? Bool   ?? true

        persist(\.$launchAtLogin,           key: Keys.launchAtLogin,          cloud: false)
        persist(\.$panicShortcutEnabled,    key: Keys.panicShortcutEnabled)
        persist(\.$panicRequiresTouchID,    key: Keys.panicRequiresTouchID,   cloud: false)
        persist(\.$proximityLockEnabled,    key: Keys.proximityLockEnabled)
        persist(\.$proximityLockDelay,      key: Keys.proximityLockDelay)
        persist(\.$proximityRSSIThreshold,  key: Keys.proximityRSSIThreshold)
        persist(\.$showMenuBarStats,        key: Keys.showMenuBarStats)
        persist(\.$intruderCaptureEnabled,  key: Keys.intruderCaptureEnabled, cloud: false)
    }

    private func persist<T>(_ kp: KeyPath<SettingsStore, Published<T>.Publisher>, key: String, cloud: Bool = true) {
        self[keyPath: kp]
            .dropFirst()
            .sink { value in
                UserDefaults.standard.set(value, forKey: key)
                if cloud { NSUbiquitousKeyValueStore.default.set(value, forKey: key) }
            }
            .store(in: &cancellables)
    }

    // MARK: - iCloud Sync

    func syncFromCloud(_ store: NSUbiquitousKeyValueStore) {
        applyCloudUpdate(store, keys: Set(Keys.allCloudKeys))
    }

    func applyCloudUpdate(_ store: NSUbiquitousKeyValueStore, keys: Set<String>) {
        if keys.contains(Keys.panicShortcutEnabled),
           let v = store.object(forKey: Keys.panicShortcutEnabled) as? Bool  { panicShortcutEnabled = v }
        if keys.contains(Keys.proximityLockEnabled),
           let v = store.object(forKey: Keys.proximityLockEnabled) as? Bool  { proximityLockEnabled = v }
        if keys.contains(Keys.proximityLockDelay),
           let v = store.object(forKey: Keys.proximityLockDelay) as? Double  { proximityLockDelay = v }
        if keys.contains(Keys.proximityRSSIThreshold),
           let v = store.object(forKey: Keys.proximityRSSIThreshold) as? Double { proximityRSSIThreshold = v }
        if keys.contains(Keys.showMenuBarStats),
           let v = store.object(forKey: Keys.showMenuBarStats) as? Bool      { showMenuBarStats = v }
    }

    private enum Keys {
        static let launchAtLogin          = "launchAtLogin"
        static let panicShortcutEnabled   = "panicShortcutEnabled"
        static let panicRequiresTouchID   = "panicRequiresTouchID"
        static let proximityLockEnabled   = "proximityLockEnabled"
        static let proximityLockDelay     = "proximityLockDelay"
        static let proximityRSSIThreshold = "proximityRSSIThreshold"
        static let showMenuBarStats       = "showMenuBarStats"
        static let intruderCaptureEnabled = "intruderCaptureEnabled"

        // launchAtLogin, panicRequiresTouchID, intruderCaptureEnabled are per-machine security controls
        static let allCloudKeys: [String] = [
            panicShortcutEnabled, proximityLockEnabled,
            proximityLockDelay, proximityRSSIThreshold, showMenuBarStats
        ]
    }
}
