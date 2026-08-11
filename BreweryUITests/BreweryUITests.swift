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

    /// Focus the search field via the app's own ⌘F command. A synthetic `.click()` on the field
    /// only hovers on macOS, which let the typing tests pass while typing nowhere — a test that
    /// measures nothing is worse than no test, so every caller asserts on the field's value after.
    @discardableResult
    private func focusSearch(_ app: XCUIApplication, typing text: String) -> XCUIElement {
        app.typeKey("f", modifierFlags: .command)
        app.typeText(text)
        let field = app.searchFields.firstMatch
        XCTAssertEqual(field.value as? String, text,
                       "Text never reached the search field — the test would be measuring nothing.")
        return field
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
        app.typeKey("f", modifierFlags: .command)

        var worst: TimeInterval = 0
        var typed = ""
        for character in ["w", "g", "e", "t"] {
            let start = Date()
            app.typeText(character)
            let elapsed = Date().timeIntervalSince(start)
            print("KEYSTROKE_SECONDS \(character) \(elapsed)")
            worst = max(worst, elapsed)
            typed += character
        }
        print("WORST_KEYSTROKE_SECONDS \(worst)")
        XCTAssertEqual(field.value as? String, typed,
                       "Keystrokes never reached the field, so these timings mean nothing.")
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

        // Scoped to the sidebar: since cards grew an "Installed" state label, bare staticText
        // queries can match a card and become ambiguous.
        let outdated = app.outlines["Sidebar"].staticTexts["Outdated"].exists
            ? app.outlines["Sidebar"].staticTexts["Outdated"]
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
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 60))
        sleep(20)

        let field = focusSearch(app, typing: "vim")
        sleep(2)
        let searched = app.buttons.matching(NSPredicate(format: "label == %@", "Install")).count
        XCTAssertLessThan(searched, 40, "Search did not narrow the grid; got \(searched) cards.")

        app.outlines["Sidebar"].staticTexts["Installed"].click()
        sleep(2)
        app.outlines["Sidebar"].staticTexts["Discover"].click()

        // Read immediately — no settle — so a fallback to the full listing would be caught.
        let onReturn = app.buttons.matching(NSPredicate(format: "label == %@", "Install")).count
        print("CARDS_AFTER_RETURN \(onReturn) vs SEARCHED \(searched)")
        XCTAssertLessThan(onReturn, 40,
                          "Returning to Discover showed the unfiltered listing (\(onReturn) cards).")
        XCTAssertEqual(field.value as? String, "vim", "The query was not restored.")
    }
}

/// Regression: narrowing a search down to a single card must not shift the grid vertically.
extension BreweryUITests {
    /// Cards are the only large buttons on screen; toolbar items are small.
    private func topCardY(_ app: XCUIApplication) -> (y: CGFloat, count: Int) {
        let cards = app.buttons.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.height > 100 && $0.width > 150 }
        return (cards.map(\.origin.y).min() ?? -1, cards.count)
    }

    func testGridDoesNotShiftWhenNarrowingToOneResult() throws {
        let app = launched()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 60))
        sleep(20)

        focusSearch(app, typing: "wget")
        sleep(2)
        let many = topCardY(app)
        XCTAssertGreaterThan(many.count, 1, "Expected several cards for the wider query.")

        app.typeText("paste")   // appended -> "wgetpaste", a single result
        sleep(2)
        let one = topCardY(app)
        XCTAssertEqual(one.count, 1, "Expected exactly one card.")

        print("GRID_Y many=\(many.y) (\(many.count) cards) one=\(one.y) (\(one.count) cards) delta=\(one.y - many.y)")
        XCTAssertEqual(one.y, many.y, accuracy: 0.5,
                       "Grid shifted by \(one.y - many.y)pt when narrowing to one result.")
    }
}

/// The menu bar is the macOS command surface: every destination has to be reachable from it, and
/// from the keyboard alone. Asserted through the window title, which names the section.
extension BreweryUITests {
    func testSectionShortcutsSwitchSections() throws {
        let app = launched()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 60))
        sleep(15)

        let window = app.windows.firstMatch
        for (key, section) in [("2", "Installed"), ("3", "Outdated"), ("5", "Taps"), ("1", "Discover")] {
            app.typeKey(key, modifierFlags: .command)
            sleep(1)
            XCTAssertTrue(window.title.hasPrefix(section),
                          "⌘\(key) should reach \(section); the window says “\(window.title)”.")
        }

        // Every toolbar action needs its menu bar command, so the menus themselves must exist.
        for menu in ["View", "Homebrew", "Help"] {
            XCTAssertTrue(app.menuBars.menuBarItems[menu].exists, "No \(menu) menu.")
        }
    }
}

/// Regression: a TipView sharing the view tree with `ContentUnavailableView.search` blanks the
/// split view's sidebar (framework interaction, macOS 26). The tip is gated to browsing; this
/// pins that an empty search keeps the sidebar rendered.
extension BreweryUITests {
    func testEmptySearchKeepsSidebar() throws {
        let app = launched()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 60))
        sleep(15)

        focusSearch(app, typing: "zzzznotapackage")
        sleep(2)

        XCTAssertTrue(app.staticTexts["No Results for “zzzznotapackage”"].exists
                      || app.staticTexts["Check the spelling or try a new search."].exists,
                      "Empty state never appeared.")
        for section in ["Discover", "Installed", "Outdated", "Services", "Taps"] {
            XCTAssertTrue(app.outlines["Sidebar"].staticTexts[section].isHittable,
                          "Sidebar lost \(section) during an empty search.")
        }
    }
}
