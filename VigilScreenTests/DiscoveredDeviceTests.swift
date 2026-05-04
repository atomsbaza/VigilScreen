import XCTest
@testable import VigilScreen

final class DiscoveredDeviceTests: XCTestCase {

    // MARK: - signalDescription thresholds

@MainActor func testExcellent_atBoundary() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -60)
        XCTAssertEqual(device.signalDescription, "Excellent")
    }

@MainActor func testExcellent_above() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -40)
        XCTAssertEqual(device.signalDescription, "Excellent")
    }

@MainActor func testGood_atBoundary() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -70)
        XCTAssertEqual(device.signalDescription, "Good")
    }

@MainActor func testGood_between() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -65)
        XCTAssertEqual(device.signalDescription, "Good")
    }

@MainActor func testFair_atBoundary() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -80)
        XCTAssertEqual(device.signalDescription, "Fair")
    }

@MainActor func testFair_between() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -75)
        XCTAssertEqual(device.signalDescription, "Fair")
    }

@MainActor func testWeak_justBelow() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -81)
        XCTAssertEqual(device.signalDescription, "Weak")
    }

@MainActor func testWeak_veryLow() {
        let device = DiscoveredDevice(uuid: UUID(), name: "A", rssi: -100)
        XCTAssertEqual(device.signalDescription, "Weak")
    }

    // MARK: - Identifiable

@MainActor func testId_isUniquePerInstance() {
        let uuid = UUID()
        let a = DiscoveredDevice(uuid: uuid, name: "Phone", rssi: -65)
        let b = DiscoveredDevice(uuid: uuid, name: "Phone", rssi: -65)
        XCTAssertNotEqual(a.id, b.id)
    }

@MainActor func testSameInstance_isEqualToItself() {
        let device = DiscoveredDevice(uuid: UUID(), name: "Phone", rssi: -65)
        XCTAssertEqual(device, device)
    }
}
