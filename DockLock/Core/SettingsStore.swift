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

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let d = UserDefaults.standard
        launchAtLogin         = d.bool(forKey: Keys.launchAtLogin)
        panicShortcutEnabled  = d.object(forKey: Keys.panicShortcutEnabled)  as? Bool   ?? true
        panicRequiresTouchID  = d.object(forKey: Keys.panicRequiresTouchID)  as? Bool   ?? true
        proximityLockEnabled  = d.bool(forKey: Keys.proximityLockEnabled)
        proximityLockDelay    = d.object(forKey: Keys.proximityLockDelay)    as? Double ?? 10.0
        proximityRSSIThreshold = d.object(forKey: Keys.proximityRSSIThreshold) as? Double ?? -75.0

        persist(\.$launchAtLogin,         key: Keys.launchAtLogin)
        persist(\.$panicShortcutEnabled,  key: Keys.panicShortcutEnabled)
        persist(\.$panicRequiresTouchID,  key: Keys.panicRequiresTouchID)
        persist(\.$proximityLockEnabled,  key: Keys.proximityLockEnabled)
        persist(\.$proximityLockDelay,    key: Keys.proximityLockDelay)
        persist(\.$proximityRSSIThreshold, key: Keys.proximityRSSIThreshold)
    }

    private func persist<T>(_ kp: KeyPath<SettingsStore, Published<T>.Publisher>, key: String) {
        self[keyPath: kp]
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: key) }
            .store(in: &cancellables)
    }

    private enum Keys {
        static let launchAtLogin          = "launchAtLogin"
        static let panicShortcutEnabled   = "panicShortcutEnabled"
        static let panicRequiresTouchID   = "panicRequiresTouchID"
        static let proximityLockEnabled   = "proximityLockEnabled"
        static let proximityLockDelay     = "proximityLockDelay"
        static let proximityRSSIThreshold = "proximityRSSIThreshold"
    }
}
