import XCTest
@testable import DockLock

/// Tests for AppBlocklist. Uses the shared singleton; cleans up UserDefaults before each test.
@MainActor
final class AppBlocklistTests: XCTestCase {

    private let udKey = "panicBlocklist"

    override func setUp() {
        super.setUp()
        // Remove persisted list so each test starts clean
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: udKey)
        super.tearDown()
    }

    // MARK: - Default list

    func testDefaultsContainsTerminal() {
        XCTAssertTrue(AppBlocklist.defaults.contains("com.apple.Terminal"))
    }

    func testDefaultsContainsXcode() {
        XCTAssertTrue(AppBlocklist.defaults.contains("com.apple.dt.Xcode"))
    }

    func testDefaultsContainsVSCode() {
        XCTAssertTrue(AppBlocklist.defaults.contains("com.microsoft.VSCode"))
    }

    func testDefaultsContainsSafari() {
        XCTAssertTrue(AppBlocklist.defaults.contains("com.apple.Safari"))
    }

    func testDefaultsContainsChrome() {
        XCTAssertTrue(AppBlocklist.defaults.contains("com.google.Chrome"))
    }

    func testDefaultsContainsSlack() {
        XCTAssertTrue(AppBlocklist.defaults.contains("com.tinyspeck.slackmacgap"))
    }

    func testDefaultsContainsNotion() {
        XCTAssertTrue(AppBlocklist.defaults.contains("notion.id"))
    }

    func testDefaultsCount() {
        XCTAssertEqual(AppBlocklist.defaults.count, 7)
    }

    // MARK: - Add / Remove

    func testAdd_insertsID() {
        let id = "com.test.AddTest"
        AppBlocklist.shared.add(id)
        XCTAssertTrue(AppBlocklist.shared.bundleIDs.contains(id))
        AppBlocklist.shared.remove(id)
    }

    func testRemove_deletesID() {
        let id = "com.test.RemoveTest"
        AppBlocklist.shared.add(id)
        AppBlocklist.shared.remove(id)
        XCTAssertFalse(AppBlocklist.shared.bundleIDs.contains(id))
    }

    func testAdd_doesNotDuplicate() {
        let id = "com.test.DupTest"
        let countBefore = AppBlocklist.shared.bundleIDs.count
        AppBlocklist.shared.add(id)
        AppBlocklist.shared.add(id)
        XCTAssertEqual(AppBlocklist.shared.bundleIDs.count, countBefore + 1)
        AppBlocklist.shared.remove(id)
    }

    // MARK: - UserDefaults persistence

    func testAdd_persistsToUserDefaults() {
        let id = "com.test.PersistTest"
        AppBlocklist.shared.add(id)
        // Allow Combine sink to fire
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.stringArray(forKey: udKey) ?? []
        XCTAssertTrue(saved.contains(id))
        AppBlocklist.shared.remove(id)
    }

    func testRemove_updatesUserDefaults() {
        let id = "com.test.RemovePersistTest"
        AppBlocklist.shared.add(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        AppBlocklist.shared.remove(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.stringArray(forKey: udKey) ?? []
        XCTAssertFalse(saved.contains(id))
    }
}
