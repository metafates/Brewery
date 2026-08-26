//
//  HarnessTests.swift
//  BreweryUITests
//
//  Created by metafates on 23.08.2026.
//
//  The deterministic harness's proving tests: mutations and error paths the real-machine suite
//  can never touch (its standing rule is "never enqueue against the dev machine"). Everything
//  between the two faked process boundaries runs for real — the queue, the Process spawn, the
//  parsers, the reconcile, the render.
//

import XCTest

final class HarnessTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var wget2: FixturePackage {
        FixturePackage(name: "wget2", desc: "Successor of the wget download tool", version: "2.2.0")
    }

    private func card(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == 'PackageCard' AND label CONTAINS %@", fragment)).firstMatch
    }

    /// Install runs end to end: click → queue → fake-brew spawn → exit 0 applies the changed
    /// world → the app's own probes re-read it → the package appears in Installed.
    func testInstallFlowRunsEndToEnd() {
        var installed = wget2
        installed.installedVersions = ["2.2.0"]
        var scenario = Scenario(packages: [wget2])
        scenario.brewCommand(["install", "--formula", "wget2"],
                             stdout: "==> Fetching wget2\n==> Pouring wget2\n🍺 Done\n",
                             after: [installed])
        let app = scenario.launch(in: self)

        XCTAssertTrue(card(app, containing: "wget2").waitForExistence(timeout: 30))
        app.buttons["Install"].click()

        // The reconcile is the assertion: only a parsed post-mutation probe can put the
        // package into the Installed section's listing.
        app.outlines["Sidebar"].staticTexts["Installed"].click()
        XCTAssertTrue(card(app, containing: "wget2").waitForExistence(timeout: 20))
    }

    /// A failing brew surfaces: the operations popover auto-presents, the toolbar button wears
    /// the failure tell after dismissal, and the card returns to Install once the busy hold
    /// releases — the world did not change.
    func testFailedInstallPresentsTheFailure() {
        var scenario = Scenario(packages: [wget2])
        scenario.brewCommand(["install", "--formula", "wget2"],
                             stderr: "Error: an unsatisfied requirement failed this build.\n",
                             exitCode: 1)
        let app = scenario.launch(in: self)

        XCTAssertTrue(card(app, containing: "wget2").waitForExistence(timeout: 30))
        app.buttons["Install"].click()

        XCTAssertTrue(app.buttons["Show Log"].waitForExistence(timeout: 15),
                      "the operations popover should auto-present on failure")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(app.buttons["Operations, last operation failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Install"].waitForExistence(timeout: 10))
    }

    /// `installBrew: false` is the brew-missing scenario — and the interlock's proof: a harness
    /// launch that names no fake resolves to "not installed", never to the machine's real brew.
    func testBrewMissingShowsUnavailableState() {
        let app = Scenario(packages: [wget2], brewInstalled: false).launch(in: self)

        XCTAssertTrue(app.staticTexts["Homebrew Not Found"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.links["Install Homebrew"].exists
                      || app.buttons["Install Homebrew"].exists)

        // The dialogs and the add-tap popover live on `splitView`, which this state replaces —
        // so a command that only sets a pending flag would latch it with nothing to consume
        // it, and the next successful Check Again would present a destructive confirmation
        // nobody asked for. Refresh must stay enabled: it is the re-probe. One bound walk,
        // menu closed — the subscript binds a label these items do not carry.
        let items = app.menuBars.menuBarItems["Homebrew"].menuItems.allElementsBoundByIndex
        for title in ["Clean Up…", "Add Tap…", "Run Checkup"] {
            let item = items.first { $0.title == title }
            XCTAssertNotNil(item, "\(title) is missing from the Homebrew menu")
            XCTAssertFalse(item?.isEnabled ?? true, "\(title) must be disabled with brew missing")
        }
        XCTAssertTrue(items.first { $0.title == "Refresh" }?.isEnabled ?? false,
                      "Refresh is the re-probe and must stay enabled")
    }

    /// Maintenance renders both of its halves from real probe output: the storage card (the
    /// multi-keg fixture is what gives it something to reclaim) and the one row section this
    /// machine can reach through the harness. The old assertion watched the Old Versions band's
    /// total agree with the gauge's segment; that band is gone precisely because the two were
    /// the same number printed twice, so what is worth pinning now is that the card states the
    /// outcome and the retired package still gets a row of its own.
    func testMaintenancePageRenders() {
        var multiKeg = FixturePackage(name: "wget2", desc: "Successor of the wget download tool",
                                      version: "2.2.0")
        multiKeg.installedVersions = ["2.1.0", "2.2.0"]
        var retired = FixturePackage(name: "oldpkg", desc: "A retired fixture package",
                                     version: "1.0", deprecated: true)
        retired.installedVersions = ["1.0"]
        let app = Scenario(packages: [multiKeg, retired]).launch(in: self)

        app.outlines["Sidebar"].staticTexts["Maintenance"].click()

        // Either phrasing of the same claim: the fake Cellar holds no real keg bytes, so the
        // harness world legitimately measures zero and the headline says so in three words.
        let headline = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS 'can be freed up' OR value CONTAINS 'Nothing to clean up'"))
            .firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 60),
                      "the storage card never stated its total")
        // Section headers fuse their title, count and explainer into one AX element, so match
        // the heading rather than a bare staticText — the List-row button lesson, one level up.
        let heading = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'No longer maintained'")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20),
                      "a deprecated installed package must land under No longer maintained")
        // `.accessibilityElement(children: .combine)` fuses the row's title and state line into
        // one element, so the subtitle has no staticText of its own — and the fused *row* carries
        // it as `value` while the fused *header* above carries its own as `label`. Matching the
        // wrong one of those two finds nothing and reads exactly like a missing string.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS 'Still works, but no longer updated'")).firstMatch.exists,
                      "the retired row must state the consequence, not brew's word for it")
    }

    /// The leftovers card is the only surface `brew autoremove` has now — its rows were
    /// deliberately deleted, since the command is bulk and a row carried no decision — so it
    /// would otherwise ship with no coverage at all. This machine has no orphans, so the
    /// fixpoint's own input is seeded: a keg whose receipt says nothing asked for it
    /// (`installed_on_request`, absent = false per brew's `tab.rb`).
    func testLeftoversCardCountsOrphans() {
        var orphan = FixturePackage(name: "little-cms2", desc: "Color management engine",
                                    version: "2.17")
        orphan.installedVersions = ["2.17"]
        var scenario = Scenario(packages: [orphan])
        scenario.seedFile(
            "prefix/Cellar/little-cms2/2.17/INSTALL_RECEIPT.json",
            Data(#"{"installed_on_request": false, "poured_from_bottle": true, "runtime_dependencies": []}"#.utf8))
        let app = scenario.launch(in: self)

        app.outlines["Sidebar"].staticTexts["Maintenance"].click()

        XCTAssertTrue(app.staticTexts["1 leftover package"].waitForExistence(timeout: 60),
                      "an unrequested keg nothing depends on must reach the leftovers card")
        // The count is the card's whole claim, so the page must not also list it as a row —
        // that desync ("13 items" over twelve rows) is what the narrowed listing prevents.
        XCTAssertFalse(app.staticTexts["little-cms2"].exists,
                       "a leftover is stated as a count, not listed as a row")
    }

    /// Export runs the real read path: File ▸ Export Brewfile… → `brew bundle dump` → the save
    /// panel. The fixture deliberately writes brew chatter to **stderr** while the Brewfile
    /// goes to stdout, which is the contamination `client.capture` would have merged into the
    /// user's file — a Brewfile has no delimiters to trim back to, so a stray `==>` line would
    /// restore as a fake entry.
    func testBrewfileExportOpensTheSavePanel() {
        var scenario = Scenario(packages: [wget2])
        scenario.brewCommand(["bundle", "dump"],
                             stdout: "tap \"homebrew/cask\"\nbrew \"wget2\"\n",
                             stderr: "==> Downloading Homebrew API data\n")
        let app = scenario.launch(in: self)
        XCTAssertTrue(card(app, containing: "wget2").waitForExistence(timeout: 30))

        exportBrewfile(in: app)

        // `.fileExporter` only presents when the dump produced text, so the panel appearing is
        // the assertion that the read path worked end to end.
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20), "the save panel never appeared")
        XCTAssertTrue(app.sheets.textFields.firstMatch.value as? String == "Brewfile"
                      || panel.staticTexts["Brewfile"].exists,
                      "the panel should default to the name brew itself uses")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The one user-facing write failure in the app: every other file write is best-effort and
    /// silent, which is right for a cache and wrong for something the user asked for.
    func testBrewfileExportFailureIsExplained() {
        var scenario = Scenario(packages: [wget2])
        scenario.brewCommand(["bundle", "dump"],
                             stderr: "Error: Cannot write to the Brewfile.\n",
                             exitCode: 1)
        let app = scenario.launch(in: self)
        XCTAssertTrue(card(app, containing: "wget2").waitForExistence(timeout: 30))

        exportBrewfile(in: app)

        // brew's own sentence, not a generic apology.
        XCTAssertTrue(app.staticTexts["Cannot write to the Brewfile."].waitForExistence(timeout: 20),
                      "the alert should carry brew's own Error: line")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// One bound walk over a closed menu — the recorded shape; clicking a menuBarItem and then
    /// re-querying its children hangs the runner mid-menu-tracking.
    private func exportBrewfile(in app: XCUIApplication) {
        let item = app.menuBars.menuBarItems["File"].menuItems
            .allElementsBoundByIndex.first { $0.title == "Export Brewfile…" }
        XCTAssertNotNil(item, "File ▸ Export Brewfile… is missing")
        item?.click()
    }

    /// A 500 on the catalog with no cache lands on the designed failure state, through the real
    /// client: the fixture is a `.status` file, not a stubbed error value.
    func testCatalogFailureOffersTryAgain() {
        var scenario = Scenario()
        scenario.httpOverride(path: "/api/formula.json", body: Data(), status: 500)
        let app = scenario.launch(in: self)

        XCTAssertTrue(app.staticTexts["Couldn't Load Catalog"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }

    /// The ETag path end to end: the first launch stores validators with the cache; the second —
    /// against an aged cache and a *changed* fixture body under the *same* etag — must show the
    /// first generation still, because a matching If-None-Match came back 304 and the app reused
    /// its decoded world instead of re-downloading. A broken conditional branch would either
    /// swap to the second generation (revalidation ignored) or error (304 mishandled).
    func testUnchangedCatalogRevalidatesWith304() throws {
        let root = Scenario.makeRoot()
        let generationOne = FixturePackage(name: "etagpkg1", desc: "Generation one", version: "1.0")
        let app = Scenario(packages: [generationOne], etag: "\"gen-1\"").launch(in: self, root: root)
        XCTAssertTrue(card(app, containing: "etagpkg1").waitForExistence(timeout: 30))
        app.terminate()

        let aged = try agedCatalogCache(at: root)

        let generationTwo = FixturePackage(name: "etagpkg2", desc: "Generation two", version: "2.0")
        var second = Scenario(packages: [generationTwo], etag: "\"gen-1\"")
        // Ships the aged cache back through the payload: the runner may *read* app-written
        // files but not write them (EPERM — the OS policy the payload design exists to avoid),
        // so the app overwrites its own cache during fixture install.
        second.seedFile("support/catalog.json", aged)
        let relaunched = second.launch(in: self, root: root)
        XCTAssertTrue(card(relaunched, containing: "etagpkg1").waitForExistence(timeout: 30))
        // Give a wrongly unconditional refetch the time it would need to swap generations.
        sleep(3)
        XCTAssertFalse(card(relaunched, containing: "etagpkg2").exists)
        XCTAssertTrue(card(relaunched, containing: "etagpkg1").exists)
    }

    /// The loading rule's pin: a refresh never takes the content. ⌘R with a deliberately slow
    /// `brew update` — the toolbar button disables (the refresh is really running) while the
    /// cards stay hittable and a click still opens the pane. The veil era failed both halves:
    /// content was blurred and `.disabled` for the whole span.
    func testListingStaysInteractiveDuringRefresh() {
        var installed = wget2
        installed.installedVersions = ["2.2.0"]
        var scenario = Scenario(packages: [installed])
        scenario.brewCommand(["update"], stdout: "Already up-to-date.\n", delay: 8)
        let app = scenario.launch(in: self)

        let card = card(app, containing: "wget2")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        app.typeKey("r", modifierFlags: .command)

        // The launch-time check is skipped (the harness seeds fresh-mtime metadata), so the
        // disable proves the *forced* ⌘R update is mid-sleep right now.
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"),
                                             object: app.buttons["Refresh"])], timeout: 5)
        XCTAssertTrue(card.isHittable, "Cards must stay interactive during a refresh.")
        card.click()
        // The pane's version row is pane-only text — the card never carries it — so its
        // arrival proves the inspector answered a click made mid-refresh.
        XCTAssertTrue(app.staticTexts["Version 2.2.0 installed"].waitForExistence(timeout: 5),
                      "The pane did not answer a click made mid-refresh.")

        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                             object: app.buttons["Refresh"])], timeout: 30)
    }

    /// The app-written cache with `fetchedAt` rewound past the 24 h window, so the relaunch
    /// revalidates. Only the date moves; the payload — packages, etags — stays byte-honest.
    private func agedCatalogCache(at root: URL) throws -> Data {
        let cacheURL = root.appending(path: "support/catalog.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: cacheURL)) as? [String: Any])
        let fetchedAt = try XCTUnwrap(object["fetchedAt"] as? Double)
        object["fetchedAt"] = fetchedAt - 100_000
        return try JSONSerialization.data(withJSONObject: object)
    }
}
