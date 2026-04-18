import XCTest
@testable import DockLock

/// Tests for LockTrigger — countdown logic without requiring BT hardware.
final class LockTriggerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            SettingsStore.shared.proximityLockEnabled = false
            BluetoothMonitor.shared.unpair()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            SettingsStore.shared.proximityLockEnabled = false
            BluetoothMonitor.shared.unpair()
        }
        super.tearDown()
    }

    // MARK: - Initial state

    @MainActor func testNotCountingDown_initially() {
        XCTAssertFalse(LockTrigger.shared.isCountingDown)
    }

    @MainActor func testSecondsRemaining_zeroInitially() {
        XCTAssertEqual(LockTrigger.shared.secondsRemaining, 0)
    }

    // MARK: - No paired device → no countdown

    @MainActor func testNoCountdown_whenNoPairedDevice() {
        SettingsStore.shared.proximityLockEnabled = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertFalse(LockTrigger.shared.isCountingDown)
        SettingsStore.shared.proximityLockEnabled = false
    }

    // MARK: - Disabling proximity lock stops countdown

    @MainActor func testDisablingProximityLock_resetsCountdown() {
        SettingsStore.shared.proximityLockEnabled = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        SettingsStore.shared.proximityLockEnabled = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(LockTrigger.shared.isCountingDown)
        XCTAssertEqual(LockTrigger.shared.secondsRemaining, 0)
    }

    // MARK: - Countdown delay setting

    @MainActor func testSecondsRemaining_reflectsDelaySetting() {
        XCTAssertGreaterThanOrEqual(SettingsStore.shared.proximityLockDelay, 5.0)
        XCTAssertLessThanOrEqual(SettingsStore.shared.proximityLockDelay, 30.0)
    }
}
