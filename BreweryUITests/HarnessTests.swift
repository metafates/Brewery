//
//  HarnessTests.swift
//  BreweryUITests
//
//  Created by vzbarashchenko on 23.08.2026.
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
