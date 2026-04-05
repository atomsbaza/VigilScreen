import XCTest
@testable import DockLock

final class DiscoveredDeviceTests: XCTestCase {

    // MARK: - signalDescription thresholds

    func testExcellent_atBoundary() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -60)
        XCTAssertEqual(device.signalDescription, "Excellent")
    }

    func testExcellent_above() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -40)
        XCTAssertEqual(device.signalDescription, "Excellent")
    }

    func testGood_atBoundary() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -70)
        XCTAssertEqual(device.signalDescription, "Good")
    }

    func testGood_between() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -65)
        XCTAssertEqual(device.signalDescription, "Good")
    }

    func testFair_atBoundary() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -80)
        XCTAssertEqual(device.signalDescription, "Fair")
    }

    func testFair_between() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -75)
        XCTAssertEqual(device.signalDescription, "Fair")
    }

    func testWeak_justBelow() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -81)
        XCTAssertEqual(device.signalDescription, "Weak")
    }

    func testWeak_veryLow() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -100)
        XCTAssertEqual(device.signalDescription, "Weak")
    }

    // MARK: - Identifiable

    func testId_isUniquePerInstance() {
        // Each instance gets its own auto-generated id, so two separate instances
        // are never considered the same Identifiable even with identical data.
        let uuid = UUID()
        let a = DiscoveredDevice(uuid: uuid, name: "Phone", rssi: -65)
        let b = DiscoveredDevice(uuid: uuid, name: "Phone", rssi: -65)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testSameInstance_isEqualToItself() {
        let device = DiscoveredDevice(uuid: UUID(), name: "Phone", rssi: -65)
        XCTAssertEqual(device, device)
    }
}
