import Foundation

/// Routes NSUbiquitousKeyValueStore external-change notifications to the appropriate store.
/// Requires `com.apple.developer.ubiquity-kvstore-identifier` entitlement — add it via
/// Xcode → Signing & Capabilities → iCloud → Key-value storage when the paid developer
/// account is ready. Without the entitlement the KV store silently no-ops and the app
/// continues working via UserDefaults only.
@MainActor
final class CloudSyncStore {
    static let shared = CloudSyncStore()

    private let kvStore = NSUbiquitousKeyValueStore.default

    // panicRequiresTouchID and intruderCaptureEnabled are local-only security controls — not synced
    private static let settingsKeys: Set<String> = [
        "panicShortcutEnabled", "proximityLockEnabled",
        "proximityLockDelay", "proximityRSSIThreshold", "showMenuBarStats"
    ]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
    }

    /// Call once at launch to pull any iCloud values that arrived while the app was quit.
    func synchronize() {
        kvStore.synchronize()
        SettingsStore.shared.syncFromCloud(kvStore)
        AppSafelist.shared.syncFromCloud(kvStore)
        LockHistoryStore.shared.syncFromCloud(kvStore)
    }

    @objc private func handleExternalChange(_ note: Notification) {
        guard let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
        let keys = Set(changed)
        if !keys.isDisjoint(with: Self.settingsKeys) {
            SettingsStore.shared.applyCloudUpdate(kvStore, keys: keys)
        }
        if keys.contains("panicBlocklist") {
            AppSafelist.shared.applyCloudUpdate(kvStore)
        }
        if keys.contains("lockHistory") {
            LockHistoryStore.shared.applyCloudUpdate(kvStore)
        }
    }
}
