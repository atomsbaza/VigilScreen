import Foundation
import Combine

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var launchAtLogin: Bool
    @Published var panicShortcutEnabled: Bool
    @Published var panicRequiresTouchID: Bool
    @Published var panicAutoMuteAudio: Bool
    @Published var panicClearClipboard: Bool
    @Published var proximityLockEnabled: Bool
    @Published var proximityLockDelay: Double
    @Published var proximityRSSIThreshold: Double
    @Published var showMenuBarStats: Bool
    @Published var intruderCaptureEnabled: Bool
    @Published var shoulderSurfingEnabled: Bool
    @Published var shoulderSurfingSensitivity: Double
    @Published var shoulderSurfingAutoRelease: Bool
    @Published var shoulderSurfingReleaseDelay: Double

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let d = UserDefaults.standard
        launchAtLogin            = d.bool(forKey: Keys.launchAtLogin)
        panicShortcutEnabled     = d.object(forKey: Keys.panicShortcutEnabled)     as? Bool   ?? true
        panicRequiresTouchID     = d.object(forKey: Keys.panicRequiresTouchID)     as? Bool   ?? true
        panicAutoMuteAudio       = d.object(forKey: Keys.panicAutoMuteAudio)       as? Bool   ?? true
        panicClearClipboard      = d.object(forKey: Keys.panicClearClipboard)      as? Bool   ?? true
        proximityLockEnabled     = d.bool(forKey: Keys.proximityLockEnabled)
        proximityLockDelay       = d.object(forKey: Keys.proximityLockDelay)       as? Double ?? 10.0
        proximityRSSIThreshold   = d.object(forKey: Keys.proximityRSSIThreshold)   as? Double ?? -75.0
        showMenuBarStats         = d.object(forKey: Keys.showMenuBarStats)         as? Bool   ?? false
        intruderCaptureEnabled   = d.object(forKey: Keys.intruderCaptureEnabled)   as? Bool   ?? true
        shoulderSurfingEnabled      = d.object(forKey: Keys.shoulderSurfingEnabled)      as? Bool   ?? false
        shoulderSurfingSensitivity  = d.object(forKey: Keys.shoulderSurfingSensitivity)  as? Double ?? 0.5
        shoulderSurfingAutoRelease  = d.object(forKey: Keys.shoulderSurfingAutoRelease)  as? Bool   ?? false
        shoulderSurfingReleaseDelay = d.object(forKey: Keys.shoulderSurfingReleaseDelay) as? Double ?? 5.0

        persist(\.$launchAtLogin,             key: Keys.launchAtLogin,            cloud: false)
        persist(\.$panicShortcutEnabled,      key: Keys.panicShortcutEnabled)
        persist(\.$panicRequiresTouchID,      key: Keys.panicRequiresTouchID,     cloud: false)
        persist(\.$panicAutoMuteAudio,        key: Keys.panicAutoMuteAudio,       cloud: false)
        persist(\.$panicClearClipboard,       key: Keys.panicClearClipboard,      cloud: false)
        persist(\.$proximityLockEnabled,      key: Keys.proximityLockEnabled)
        persist(\.$proximityLockDelay,        key: Keys.proximityLockDelay)
        persist(\.$proximityRSSIThreshold,    key: Keys.proximityRSSIThreshold)
        persist(\.$showMenuBarStats,          key: Keys.showMenuBarStats)
        persist(\.$intruderCaptureEnabled,    key: Keys.intruderCaptureEnabled,   cloud: false)
        persist(\.$shoulderSurfingEnabled,      key: Keys.shoulderSurfingEnabled,      cloud: false)
        persist(\.$shoulderSurfingSensitivity,  key: Keys.shoulderSurfingSensitivity)
        persist(\.$shoulderSurfingAutoRelease,  key: Keys.shoulderSurfingAutoRelease,  cloud: false)
        persist(\.$shoulderSurfingReleaseDelay, key: Keys.shoulderSurfingReleaseDelay)
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
        if keys.contains(Keys.shoulderSurfingSensitivity),
           let v = store.object(forKey: Keys.shoulderSurfingSensitivity) as? Double { shoulderSurfingSensitivity = v }
        if keys.contains(Keys.shoulderSurfingReleaseDelay),
           let v = store.object(forKey: Keys.shoulderSurfingReleaseDelay) as? Double { shoulderSurfingReleaseDelay = v }
    }

    private enum Keys {
        static let launchAtLogin          = "launchAtLogin"
        static let panicShortcutEnabled   = "panicShortcutEnabled"
        static let panicRequiresTouchID   = "panicRequiresTouchID"
        static let panicAutoMuteAudio     = "panicAutoMuteAudio"
        static let panicClearClipboard    = "panicClearClipboard"
        static let proximityLockEnabled   = "proximityLockEnabled"
        static let proximityLockDelay     = "proximityLockDelay"
        static let proximityRSSIThreshold = "proximityRSSIThreshold"
        static let showMenuBarStats       = "showMenuBarStats"
        static let intruderCaptureEnabled    = "intruderCaptureEnabled"
        static let shoulderSurfingEnabled      = "shoulderSurfingEnabled"
        static let shoulderSurfingSensitivity  = "shoulderSurfingSensitivity"
        static let shoulderSurfingAutoRelease  = "shoulderSurfingAutoRelease"
        static let shoulderSurfingReleaseDelay = "shoulderSurfingReleaseDelay"

        // launchAtLogin, panicRequiresTouchID, panicAutoMuteAudio, panicClearClipboard, intruderCaptureEnabled, shoulderSurfingEnabled/AutoRelease are per-machine security controls
        static let allCloudKeys: [String] = [
            panicShortcutEnabled, proximityLockEnabled,
            proximityLockDelay, proximityRSSIThreshold, showMenuBarStats,
            shoulderSurfingSensitivity, shoulderSurfingReleaseDelay
        ]
    }
}
