import XCTest
@testable import DockLock

// MARK: - State machine tests

final class PanicModeStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // TouchID auth always fails in tests; disable it so releasePanic() calls unhideAll() directly.
        MainActor.assumeIsolated {
            SettingsStore.shared.panicRequiresTouchID = false
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            SettingsStore.shared.panicRequiresTouchID = false
            if PanicModeManager.shared.isActive {
                PanicModeManager.shared.releasePanic()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        super.tearDown()
    }

    @MainActor func testIsActive_isFalseInitially() {
        XCTAssertFalse(PanicModeManager.shared.isActive)
    }

    @MainActor func testTriggerPanic_setsIsActiveTrue() {
        PanicModeManager.shared.triggerPanic()
        XCTAssertTrue(PanicModeManager.shared.isActive)
    }

    @MainActor func testReleasePanic_setsIsActiveFalse() {
        PanicModeManager.shared.triggerPanic()
        PanicModeManager.shared.releasePanic()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(PanicModeManager.shared.isActive)
    }

    @MainActor func testReleasePanic_whenNotActive_remainsFalse() {
        XCTAssertFalse(PanicModeManager.shared.isActive)
        PanicModeManager.shared.releasePanic()
        XCTAssertFalse(PanicModeManager.shared.isActive)
    }

    @MainActor func testTriggerPanic_idempotent_doesNotDoubleRecord() {
        let countBefore = LockHistoryStore.shared.events.count
        PanicModeManager.shared.triggerPanic()
        PanicModeManager.shared.triggerPanic() // already active — no second record
        XCTAssertEqual(LockHistoryStore.shared.events.count, countBefore + 1)
    }
}
