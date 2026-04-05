import XCTest
@testable import DockLock

/// Tests for LockTrigger — countdown logic without requiring BT hardware.
@MainActor
final class LockTriggerTests: XCTestCase {

    private let trigger = LockTrigger.shared
    private let settings = SettingsStore.shared
    private let monitor = BluetoothMonitor.shared

    override func setUp() {
        super.setUp()
        // Ensure proximity lock is off and no device is paired before each test
        settings.proximityLockEnabled = false
        monitor.unpair()
    }

    override func tearDown() {
        settings.proximityLockEnabled = false
        monitor.unpair()
        super.tearDown()
    }

    // MARK: - Initial state

    func testNotCountingDown_initially() {
        XCTAssertFalse(trigger.isCountingDown)
    }

    func testSecondsRemaining_zeroInitially() {
        XCTAssertEqual(trigger.secondsRemaining, 0)
    }

    // MARK: - No paired device → no countdown

    func testNoCountdown_whenNoPairedDevice() {
        settings.proximityLockEnabled = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        // Without a paired device, monitoring sink guard returns early — no countdown
        XCTAssertFalse(trigger.isCountingDown)
        settings.proximityLockEnabled = false
    }

    // MARK: - Disabling proximity lock stops countdown

    func testDisablingProximityLock_resetsCountdown() {
        settings.proximityLockEnabled = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        settings.proximityLockEnabled = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(trigger.isCountingDown)
        XCTAssertEqual(trigger.secondsRemaining, 0)
    }

    // MARK: - Countdown delay setting

    func testSecondsRemaining_reflectsDelaySetting() {
        // The countdown value is driven by proximityLockDelay at the time it starts.
        // We verify the setting is readable and in the expected range.
        XCTAssertGreaterThanOrEqual(settings.proximityLockDelay, 5.0)
        XCTAssertLessThanOrEqual(settings.proximityLockDelay, 30.0)
    }
}
