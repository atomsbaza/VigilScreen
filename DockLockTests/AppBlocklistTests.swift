import XCTest
@testable import DockLock

/// Tests for AppSafelist. Uses the shared singleton; cleans up UserDefaults before each test.
final class AppBlocklistTests: XCTestCase {

    private let udKey = "panicBlocklist"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: udKey)
        super.tearDown()
    }

    // MARK: - Default list

    @MainActor func testDefaultsContainsTerminal() {
        XCTAssertTrue(AppSafelist.defaults.contains("com.apple.Terminal"))
    }

    @MainActor func testDefaultsContainsXcode() {
        XCTAssertTrue(AppSafelist.defaults.contains("com.apple.dt.Xcode"))
    }

    @MainActor func testDefaultsContainsVSCode() {
        XCTAssertTrue(AppSafelist.defaults.contains("com.microsoft.VSCode"))
    }

    @MainActor func testDefaultsContainsSafari() {
        XCTAssertTrue(AppSafelist.defaults.contains("com.apple.Safari"))
    }

    @MainActor func testDefaultsContainsChrome() {
        XCTAssertTrue(AppSafelist.defaults.contains("com.google.Chrome"))
    }

    @MainActor func testDefaultsContainsSlack() {
        XCTAssertTrue(AppSafelist.defaults.contains("com.tinyspeck.slackmacgap"))
    }

    @MainActor func testDefaultsContainsNotion() {
        XCTAssertTrue(AppSafelist.defaults.contains("notion.id"))
    }

    @MainActor func testDefaultsCount() {
        XCTAssertEqual(AppSafelist.defaults.count, 7)
    }

    // MARK: - Add / Remove

    @MainActor func testAdd_insertsID() {
        let id = "com.test.AddTest"
        AppSafelist.shared.add(id)
        XCTAssertTrue(AppSafelist.shared.bundleIDs.contains(id))
        AppSafelist.shared.remove(id)
    }

    @MainActor func testRemove_deletesID() {
        let id = "com.test.RemoveTest"
        AppSafelist.shared.add(id)
        AppSafelist.shared.remove(id)
        XCTAssertFalse(AppSafelist.shared.bundleIDs.contains(id))
    }

    @MainActor func testAdd_doesNotDuplicate() {
        let id = "com.test.DupTest"
        let countBefore = AppSafelist.shared.bundleIDs.count
        AppSafelist.shared.add(id)
        AppSafelist.shared.add(id)
        XCTAssertEqual(AppSafelist.shared.bundleIDs.count, countBefore + 1)
        AppSafelist.shared.remove(id)
    }

    // MARK: - UserDefaults persistence

    @MainActor func testAdd_persistsToUserDefaults() {
        let id = "com.test.PersistTest"
        AppSafelist.shared.add(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.stringArray(forKey: udKey) ?? []
        XCTAssertTrue(saved.contains(id))
        AppSafelist.shared.remove(id)
    }

    @MainActor func testRemove_updatesUserDefaults() {
        let id = "com.test.RemovePersistTest"
        AppSafelist.shared.add(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        AppSafelist.shared.remove(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let saved = UserDefaults.standard.stringArray(forKey: udKey) ?? []
        XCTAssertFalse(saved.contains(id))
    }
}
