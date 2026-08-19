//
//  OperationsSurfaceTests.swift
//  BreweryUITests
//

import XCTest

/// The operations surface, pinned: the toolbar item must stay a *button* while the queue is
/// active — a bare ProgressView in a button's label hoists itself out as an AX
/// ActivityIndicator and the button vanishes from the accessibility tree, unreachable by
/// VoiceOver exactly while work runs (framework interaction) — and a row's log opens in the
/// auxiliary log window rather than inline. Uses `-demo-operation` seeding: operations only
/// exist mid-mutation, and a test must not mutate the machine.
final class OperationsSurfaceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOperationsButtonAndLogWindow() throws {
        let app = XCUIApplication()
        // The bare flag goes last: the argument-domain parser pairs `-key value`, so a
        // leading `-demo-operation` would swallow the first seed key as its value.
        app.launchArguments = UITestSeed.pinnedState + ["-demo-operation"]
        app.launch()

        // The single-window rule survives the log WindowGroup: the main window has no New
        // command. ("New Log Window" is the log scene's own framework contribution —
        // accepted, since suppressing it removes the whole File menu, Close included.)
        // Menu items are in the AX tree without opening the menu; Close is the positive
        // control proving the File menu's contents are queryable at all.
        // One enumeration, no re-resolution: menu-item queries under a menuBarItem answer to
        // `title`, and predicate/subscript re-resolution against them is flaky where a plain
        // bound-element walk is not.
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10))
        sleep(2)
        let fileItems = fileMenu.menuItems.allElementsBoundByIndex.map(\.title)
        XCTAssertTrue(fileItems.contains("Close"),
                      "The File menu's items never became queryable: \(fileItems)")
        XCTAssertFalse(fileItems.contains("New Window"),
                       "The main window must not be duplicable: \(fileItems)")

        // Exposed as a button even with the spinner-and-count label.
        let operationsButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Operations'")).firstMatch
        XCTAssertTrue(operationsButton.waitForExistence(timeout: 10))
        operationsButton.click()

        let showLog = app.buttons.matching(identifier: "Show Log").firstMatch
        XCTAssertTrue(showLog.waitForExistence(timeout: 5))
        showLog.click()

        // The auxiliary window: the log's content, and Cancel for a running operation.
        let logWindow = app.windows
            .matching(NSPredicate(format: "identifier BEGINSWITH 'operation-log'")).firstMatch
        XCTAssertTrue(logWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(logWindow.staticTexts["==> Upgrading ffmpeg"].waitForExistence(timeout: 5))
        XCTAssertTrue(logWindow.buttons["Cancel"].exists)
    }
}
