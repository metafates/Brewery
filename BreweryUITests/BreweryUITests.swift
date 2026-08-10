//
//  BreweryUITests.swift
//  BreweryUITests
//
//  Created by vzbarashchenko on 09.08.2026.
//

import XCTest

/// Smoke + responsiveness. The unit tests cover the pure logic; these exist because the
/// interaction cost of the grid — how long the app takes to answer a click or a keystroke —
/// is invisible to them and is exactly where the app has hurt.
final class BreweryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60),
                      "The app launched but never showed a window.")
        return app
    }

    /// The shell renders and the sidebar has its three sections.
    func testLaunchesAndShowsSidebarSections() throws {
        let app = launched()
        for section in ["Discover", "Installed", "Outdated"] {
            XCTAssertTrue(app.staticTexts[section].waitForExistence(timeout: 30),
                          "Sidebar is missing the \(section) section.")
        }
    }

    /// Focusing the search field must not block. This is the reported symptom: the click itself
    /// stalls, before a single character is typed.
    func testFocusingSearchFieldIsResponsive() throws {
        let app = launched()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 60), "No search field.")

        // Let the catalog land first, so this measures interaction and not startup.
        sleep(20)

        let start = Date()
        field.click()
        let elapsed = Date().timeIntervalSince(start)
        print("SEARCH_FOCUS_SECONDS \(elapsed)")
        XCTAssertLessThan(elapsed, 1.0, "Clicking the search field took \(elapsed)s.")
    }

    /// Typing must keep up. Each character is timed separately so a regression shows which
    /// keystroke pays the cost, rather than an average that hides it.
    func testTypingIsResponsive() throws {
        let app = launched()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 60), "No search field.")
        sleep(20)
        field.click()

        var worst: TimeInterval = 0
        for character in ["w", "g", "e", "t"] {
            let start = Date()
            field.typeText(character)
            let elapsed = Date().timeIntervalSince(start)
            print("KEYSTROKE_SECONDS \(character) \(elapsed)")
            worst = max(worst, elapsed)
        }
        print("WORST_KEYSTROKE_SECONDS \(worst)")
        XCTAssertLessThan(worst, 0.5, "Slowest keystroke took \(worst)s.")
    }

    /// Scrolling the grid must not stall on icon loading — an image load is decoration and must
    /// never sit between the user and the app.
    func testScrollingIsResponsive() throws {
        let app = launched()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 60))
        sleep(20)

        var worst: TimeInterval = 0
        for _ in 0..<5 {
            let start = Date()
            app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
            worst = max(worst, Date().timeIntervalSince(start))
        }
        print("WORST_SCROLL_SECONDS \(worst)")
        XCTAssertLessThan(worst, 1.0, "Slowest scroll took \(worst)s.")
    }
}

/// Isolation experiment: same click, but on a section whose grid is empty. If this is fast while
/// Discover is slow, the cost is the grid; if both are slow, it is the search field itself.
extension BreweryUITests {
    func testFocusSearchOnEmptySection() throws {
        let app = launched()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 60))
        sleep(20)

        let outdated = app.staticTexts["Outdated"].exists
            ? app.staticTexts["Outdated"]
            : app.outlines.cells.element(boundBy: 2)
        XCTAssertTrue(outdated.waitForExistence(timeout: 20), "No Outdated row.")
        let t0 = Date()
        outdated.click()
        print("SECTION_SWITCH_SECONDS \(Date().timeIntervalSince(t0))")
        sleep(2)

        let field = app.searchFields.firstMatch
        let t1 = Date()
        field.click()
        print("EMPTY_SECTION_FOCUS_SECONDS \(Date().timeIntervalSince(t1))")
    }
}

/// Regression: a query typed in one tab must still be showing *its results* on return, not the
/// unfiltered listing. The flash was brief, so this asserts the count the moment the tab is back.
extension BreweryUITests {
    func testSearchResultsSurviveTabSwitch() throws {
        let app = launched()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        sleep(20)

        field.click()
        field.typeText("vim")
        sleep(2)
        let searched = app.buttons.matching(NSPredicate(format: "label == %@", "Install")).count
        XCTAssertLessThan(searched, 40, "Search did not narrow the grid; got \(searched) cards.")

        app.staticTexts["Installed"].click()
        sleep(2)
        app.staticTexts["Discover"].click()

        // Read immediately — no settle — so a fallback to the full listing would be caught.
        let onReturn = app.buttons.matching(NSPredicate(format: "label == %@", "Install")).count
        print("CARDS_AFTER_RETURN \(onReturn) vs SEARCHED \(searched)")
        XCTAssertLessThan(onReturn, 40,
                          "Returning to Discover showed the unfiltered listing (\(onReturn) cards).")
        XCTAssertEqual(field.value as? String, "vim", "The query was not restored.")
    }
}
