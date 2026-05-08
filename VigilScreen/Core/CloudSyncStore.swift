import Combine
import Foundation

/// Routes NSUbiquitousKeyValueStore external-change notifications to the appropriate store.
@MainActor
final class CloudSyncStore: ObservableObject {
    static let shared = CloudSyncStore()

    @Published private(set) var isSignedInToICloud: Bool = false
    @Published private(set) var lastSyncedAt: Date?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshSignInStatus),
            name: .NSUbiquityIdentityDidChange,
            object: nil
        )
        refreshSignInStatus()
    }

    /// Call once at launch to pull any iCloud values that arrived while the app was quit.
    func synchronize() {
        let didSync = kvStore.synchronize()
        SettingsStore.shared.syncFromCloud(kvStore)
        AppSafelist.shared.syncFromCloud(kvStore)
        LockHistoryStore.shared.syncFromCloud(kvStore)
        if didSync { lastSyncedAt = Date() }
        refreshSignInStatus()
    }

    @objc private func refreshSignInStatus() {
        // ubiquityIdentityToken is non-nil only when the user is signed into iCloud
        // AND iCloud Drive is enabled — the prerequisites for KV-store sync.
        isSignedInToICloud = FileManager.default.ubiquityIdentityToken != nil
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
        lastSyncedAt = Date()
    }
}
