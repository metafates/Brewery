//
//  PaneRegressionUITests.swift
//  BreweryUITests
//
//  Functional smoke, not perf pins. Two regressions only a launched app could catch:
//  the refresh veil blurring an empty section's claim under the working capsule, and
//  the font preview's `.task` never firing on empty conditional content (headless
//  hosting *did* fire it — only the real hierarchy reproduced the silence).
//

import XCTest

final class PaneRegressionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launched(section: String) -> XCUIApplication {
        let app = XCUIApplication()
        // Swap the seed's section rather than appending a duplicate key.
        var seed = UITestSeed.pinnedState
        if let index = seed.firstIndex(of: "-sidebar.section") { seed[index + 1] = section }
        app.launchArguments += seed
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60),
                      "The app launched but never showed a window.")
        return app
    }

    /// Empty Updates during ⌘R: the claim must be *replaced* by the capsule, never
    /// blurred underneath it — a mid-refresh "Check Again" is the veiled-claim artifact.
    func testEmptyUpdatesReplacesClaimDuringRefresh() throws {
        let app = launched(section: "outdated")

        let claim = app.staticTexts["Everything is up to date"]
        let anyCard = app.buttons.matching(identifier: "PackageCard").firstMatch
        // Wait out the launch check; whichever lands decides whether the machine
        // qualifies for the empty-state scenario.
        let landed = claim.waitForExistence(timeout: 120)
        if !landed, anyCard.exists {
            throw XCTSkip("Machine has outdated packages — the empty state never shows.")
        }
        XCTAssertTrue(landed, "Neither the empty-updates claim nor cards ever landed.")

        app.typeKey("r", modifierFlags: .command)
        XCTAssertFalse(app.buttons["Check Again"].exists,
                       "Check Again is on screen mid-refresh — the claim was veiled, not replaced.")
        XCTAssertTrue(claim.waitForExistence(timeout: 120), "The claim never returned after ⌘R.")
    }

    /// An installed font cask's pane demonstrates its faces. Selecting a card auto-opens
    /// the pane (`select()`), so the test never toggles ⌘I.
    func testFontPreviewInPane() throws {
        let app = launched(section: "installed")
        XCTAssertTrue(app.buttons.matching(identifier: "PackageCard").firstMatch
                        .waitForExistence(timeout: 120), "Cards never landed.")
        sleep(2)

        app.typeKey("f", modifierFlags: .command)
        sleep(1)
        app.typeText("font-")
        sleep(2)

        let card = app.buttons.matching(identifier: "PackageCard").firstMatch
        guard card.waitForExistence(timeout: 10) else {
            throw XCTSkip("No font cask installed on this machine.")
        }
        card.click()
        XCTAssertTrue(app.staticTexts["Preview"].waitForExistence(timeout: 15),
                      "The font Preview section is missing from the pane.")
    }
}
