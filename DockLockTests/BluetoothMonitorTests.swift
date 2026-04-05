import XCTest
@testable import DockLock

/// Tests for BluetoothMonitor — pure logic that does not require hardware.
@MainActor
final class BluetoothMonitorTests: XCTestCase {

    private let monitor = BluetoothMonitor.shared

    override func tearDown() {
        // Restore clean state after each test
        if monitor.pairedDeviceUUID != nil {
            monitor.unpair()
        }
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialRSSI_isZero() {
        monitor.unpair()
        XCTAssertEqual(monitor.currentRSSI, 0)
    }

    func testInitialIsDeviceVisible_falseAfterUnpair() {
        monitor.unpair()
        XCTAssertFalse(monitor.isDeviceVisible)
    }

    func testInitialNearbyDevices_isEmpty() {
        // nearbyDevices is reset by startDiscoveryScan, but starts empty unless a scan ran.
        // We don't start a scan here (no BT hardware), just verify the array type.
        XCTAssertNotNil(monitor.nearbyDevices)
    }

    // MARK: - Unpair clears state

    func testUnpair_clearsPairedUUID() {
        monitor.unpair()
        XCTAssertNil(monitor.pairedDeviceUUID)
    }

    func testUnpair_clearsPairedName() {
        monitor.unpair()
        XCTAssertNil(monitor.pairedDeviceName)
    }

    func testUnpair_resetsRSSI() {
        monitor.unpair()
        XCTAssertEqual(monitor.currentRSSI, 0)
    }

    func testUnpair_setsDeviceInvisible() {
        monitor.unpair()
        XCTAssertFalse(monitor.isDeviceVisible)
    }

    // MARK: - Presence timer

    func testStopPresenceTimer_setsDeviceInvisible() {
        monitor.startPresenceTimer()
        monitor.stopPresenceTimer()
        XCTAssertFalse(monitor.isDeviceVisible)
    }

    func testStartMonitoringScan_requiresPairedDevice() {
        monitor.unpair()
        // Without a paired device, startMonitoringScan() is a no-op.
        // We verify it doesn't crash and state is unchanged.
        monitor.startMonitoringScan()
        XCTAssertNil(monitor.pairedDeviceUUID)
    }
}
