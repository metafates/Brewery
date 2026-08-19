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

    @MainActor
    func testOperationsButtonAndLogWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-operation"] + UITestSeed.pinnedState
        app.launch()

        // The single-window rule survives the log WindowGroup: no File > New Window. Wait for
        // the opened menu itself — an absence assert against an unopened menu is always green.
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10))
        fileMenu.click()
        let fileItems = fileMenu.menus.firstMatch
        XCTAssertTrue(fileItems.waitForExistence(timeout: 5))
        XCTAssertFalse(fileItems.menuItems["New Window"].exists)
        app.typeKey(.escape, modifierFlags: [])

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
