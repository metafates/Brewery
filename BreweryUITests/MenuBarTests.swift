//
//  MenuBarTests.swift
//  BreweryUITests
//

import XCTest

/// The extra's presence follows the preference — both directions, seeded through the
/// argument domain so nothing touches the user's defaults. Existence only, no timing
/// pins: a crowded menu bar or the notch can hide a status item without the app being
/// wrong, so hittability is deliberately not asserted.
final class MenuBarTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMenuBarExtraFollowsThePreference() throws {
        // One application instance, relaunched: a second XCUIApplication for the same
        // bundle right after terminate() raced the runner's accessibility attach.
        let app = XCUIApplication()
        app.launchArguments = UITestSeed.pinnedState
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 10),
                      "menubar.shown is seeded true but no status item exists.")
        app.terminate()
        sleep(2)

        // Replace the pinned value rather than appending a duplicate key — the argument
        // domain's behavior with repeated keys is not a contract worth leaning on.
        var seed = UITestSeed.pinnedState
        seed[seed.firstIndex(of: "-menubar.shown")! + 1] = "<false/>"
        app.launchArguments = seed
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
        XCTAssertFalse(app.statusItems.firstMatch.waitForExistence(timeout: 3),
                       "menubar.shown is seeded false but a status item exists.")
        app.terminate()
    }
}
