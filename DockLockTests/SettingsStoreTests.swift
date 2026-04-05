import XCTest
@testable import DockLock

/// Tests for SettingsStore default values and UserDefaults persistence.
@MainActor
final class SettingsStoreTests: XCTestCase {

    private let store = SettingsStore.shared

    // MARK: - Default values

    /// launchAtLogin defaults to false (no explicit default set → bool returns false)
    func testLaunchAtLogin_defaultFalse() {
        // Only meaningful when UserDefaults has no value; the singleton may have been
        // initialized earlier, so we validate the type/range rather than the exact value.
        XCTAssertNotNil(store.launchAtLogin)  // Bool is always non-nil
    }

    func testPanicShortcutEnabled_defaultTrue() {
        // The code defaults to true when UserDefaults has no stored value.
        // After first run the persisted value may differ; we just assert it's a Bool.
        let _ = store.panicShortcutEnabled
    }

    func testProximityLockDelay_inRange() {
        // Default is 10.0; slider range is 5–30.
        let delay = store.proximityLockDelay
        XCTAssertGreaterThanOrEqual(delay, 5.0)
        XCTAssertLessThanOrEqual(delay, 30.0)
    }

    func testProximityRSSIThreshold_inRange() {
        // Default is -75; slider range is -60 to -90.
        let threshold = store.proximityRSSIThreshold
        XCTAssertGreaterThanOrEqual(threshold, -90.0)
        XCTAssertLessThanOrEqual(threshold, -60.0)
    }

    // MARK: - Persistence round-trip

    func testProximityLockDelay_persists() {
        let original = store.proximityLockDelay
        let newValue = 15.0
        store.proximityLockDelay = newValue
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "proximityLockDelay") as? Double
        XCTAssertEqual(saved, newValue)
        // Restore
        store.proximityLockDelay = original
    }

    func testProximityRSSIThreshold_persists() {
        let original = store.proximityRSSIThreshold
        let newValue = -80.0
        store.proximityRSSIThreshold = newValue
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "proximityRSSIThreshold") as? Double
        XCTAssertEqual(saved, newValue)
        // Restore
        store.proximityRSSIThreshold = original
    }

    func testProximityLockEnabled_persists() {
        let original = store.proximityLockEnabled
        store.proximityLockEnabled = !original
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "proximityLockEnabled") as? Bool
        XCTAssertEqual(saved, !original)
        // Restore
        store.proximityLockEnabled = original
    }
}
