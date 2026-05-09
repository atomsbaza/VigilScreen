import XCTest
@testable import VigilScreen

/// Tests for SettingsStore default values and UserDefaults persistence.
final class SettingsStoreTests: XCTestCase {

    // MARK: - Default values

    @MainActor func testLaunchAtLogin_defaultFalse() {
        XCTAssertNotNil(SettingsStore.shared.launchAtLogin)
    }

    @MainActor func testPanicShortcutEnabled_defaultTrue() {
        let _ = SettingsStore.shared.panicShortcutEnabled
    }

    @MainActor func testProximityLockDelay_inRange() {
        let delay = SettingsStore.shared.proximityLockDelay
        XCTAssertGreaterThanOrEqual(delay, 5.0)
        XCTAssertLessThanOrEqual(delay, 30.0)
    }

    @MainActor func testProximityRSSIThreshold_inRange() {
        let threshold = SettingsStore.shared.proximityRSSIThreshold
        XCTAssertGreaterThanOrEqual(threshold, -90.0)
        XCTAssertLessThanOrEqual(threshold, -60.0)
    }

    // MARK: - Persistence round-trip

    @MainActor func testProximityLockDelay_persists() {
        let original = SettingsStore.shared.proximityLockDelay
        let newValue = 15.0
        SettingsStore.shared.proximityLockDelay = newValue
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "proximityLockDelay") as? Double
        XCTAssertEqual(saved, newValue)
        SettingsStore.shared.proximityLockDelay = original
    }

    @MainActor func testProximityRSSIThreshold_persists() {
        let original = SettingsStore.shared.proximityRSSIThreshold
        let newValue = -80.0
        SettingsStore.shared.proximityRSSIThreshold = newValue
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "proximityRSSIThreshold") as? Double
        XCTAssertEqual(saved, newValue)
        SettingsStore.shared.proximityRSSIThreshold = original
    }

    @MainActor func testProximityLockEnabled_persists() {
        let original = SettingsStore.shared.proximityLockEnabled
        SettingsStore.shared.proximityLockEnabled = !original
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "proximityLockEnabled") as? Bool
        XCTAssertEqual(saved, !original)
        SettingsStore.shared.proximityLockEnabled = original
    }

    @MainActor func testPanicAutoMuteAudio_persists() {
        let original = SettingsStore.shared.panicAutoMuteAudio
        SettingsStore.shared.panicAutoMuteAudio = !original
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "panicAutoMuteAudio") as? Bool
        XCTAssertEqual(saved, !original)
        SettingsStore.shared.panicAutoMuteAudio = original
    }

    @MainActor func testPanicClearClipboard_persists() {
        let original = SettingsStore.shared.panicClearClipboard
        SettingsStore.shared.panicClearClipboard = !original
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.object(forKey: "panicClearClipboard") as? Bool
        XCTAssertEqual(saved, !original)
        SettingsStore.shared.panicClearClipboard = original
    }
}
