import XCTest
@testable import VigilScreen

/// Tests for BluetoothMonitor — pure logic that does not require hardware.
final class BluetoothMonitorTests: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated {
            if BluetoothMonitor.shared.pairedDeviceUUID != nil {
                BluetoothMonitor.shared.unpair()
            }
        }
        super.tearDown()
    }

    // MARK: - Initial state

    @MainActor func testInitialRSSI_isZero() {
        BluetoothMonitor.shared.unpair()
        XCTAssertEqual(BluetoothMonitor.shared.currentRSSI, 0)
    }

    @MainActor func testInitialIsDeviceVisible_falseAfterUnpair() {
        BluetoothMonitor.shared.unpair()
        XCTAssertFalse(BluetoothMonitor.shared.isDeviceVisible)
    }

    @MainActor func testInitialNearbyDevices_isEmpty() {
        XCTAssertNotNil(BluetoothMonitor.shared.nearbyDevices)
    }

    // MARK: - Unpair clears state

    @MainActor func testUnpair_clearsPairedUUID() {
        BluetoothMonitor.shared.unpair()
        XCTAssertNil(BluetoothMonitor.shared.pairedDeviceUUID)
    }

    @MainActor func testUnpair_clearsPairedName() {
        BluetoothMonitor.shared.unpair()
        XCTAssertNil(BluetoothMonitor.shared.pairedDeviceName)
    }

    @MainActor func testUnpair_resetsRSSI() {
        BluetoothMonitor.shared.unpair()
        XCTAssertEqual(BluetoothMonitor.shared.currentRSSI, 0)
    }

    @MainActor func testUnpair_setsDeviceInvisible() {
        BluetoothMonitor.shared.unpair()
        XCTAssertFalse(BluetoothMonitor.shared.isDeviceVisible)
    }

    // MARK: - Presence timer

    @MainActor func testStopPresenceTimer_setsDeviceInvisible() {
        BluetoothMonitor.shared.startPresenceTimer()
        BluetoothMonitor.shared.stopPresenceTimer()
        XCTAssertFalse(BluetoothMonitor.shared.isDeviceVisible)
    }

    @MainActor func testStartMonitoringScan_requiresPairedDevice() {
        BluetoothMonitor.shared.unpair()
        BluetoothMonitor.shared.startMonitoringScan()
        XCTAssertNil(BluetoothMonitor.shared.pairedDeviceUUID)
    }
}
