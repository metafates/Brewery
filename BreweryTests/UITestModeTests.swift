//
//  UITestModeTests.swift
//  BreweryTests
//
//  Created by vzbarashchenko on 23.08.2026.
//

import Foundation
import Testing
@testable import Brewery

@Suite("UI-test harness")
struct UITestModeTests {
    /// The unit-test host launches without the payload variable, so every seam must answer
    /// production values — the whole harness rides on this being the default.
    @Test("the harness is inert without the payload variable")
    func hostIsInert() {
        #expect(UITestMode.active == false)
        #expect(UITestMode.brewPath == nil)
        #expect(UITestMode.supportDirectory == nil)
    }

    @Test("the payload survives a codec round trip")
    func payloadRoundTrip() throws {
        let payload = UITestMode.Payload(
            files: ["brew/list_--formula_--versions.stdout": Data("wget2 2.2.0\n".utf8)],
            installBrew: true)
        #expect(try UITestMode.Payload.decoded(from: payload.encoded()) == payload)
    }

    /// The UI-test target re-spells the encoder (no sources are shared between targets), so the
    /// wire format — base64(zlib(JSON{files, installBrew})), file bytes as base64 — is pinned
    /// here against a canned literal. A codec change that still round-trips would otherwise
    /// break every harness launch while this suite stayed green.
    @Test("the wire format decodes a canned literal")
    func pinnedWireFormat() throws {
        let literal = "q1bKzCsuSczJcSpKLVeySkvMKU7VUUrLzEktVrKqVspIzcnJ1yupKFGyUkp0z7ZVqq0FAA=="
        let decoded = try UITestMode.Payload.decoded(from: literal)
        #expect(decoded == UITestMode.Payload(files: ["hello.txt": Data("hi".utf8)],
                                              installBrew: false))
    }

    /// The stub's key grammar for the five catalog endpoints — a drifting key is a 404 that
    /// surfaces as an unrelated empty state in a 60 s UI test; a diff here is a 0.1 s failure.
    @Test("fixture keys fold the request path with underscores")
    func fixtureKeys() {
        #expect(UITestStubURLProtocol.fixtureKey(for: CatalogStore.formulaURL)
                == "api_formula.json")
        #expect(UITestStubURLProtocol.fixtureKey(for: CatalogStore.caskURL)
                == "api_cask.json")
        #expect(UITestStubURLProtocol.fixtureKey(for: CatalogStore.executablesURL)
                == "api_internal_executables.txt")
        #expect(UITestStubURLProtocol.fixtureKey(for: CatalogStore.formulaAnalyticsURL)
                == "api_analytics_install_90d.json")
        #expect(UITestStubURLProtocol.fixtureKey(for: CatalogStore.caskAnalyticsURL)
                == "api_analytics_cask-install_homebrew-cask_90d.json")
    }

    // MARK: - The fake-brew script contract

    /// The lookup-table semantics, pinned without launching the app: a hit answers its files, a
    /// miss exits 64 naming the path it wanted, a successful mutation's `.apply/` tree lands in
    /// the state overlay (and a failed one's does not), and the overlay wins later lookups.
    @Test("fake brew answers fixtures, applies state on success only")
    func fakeBrewContract() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ name: String, _ contents: String) throws {
            let url = root.appending(path: "brew/\(name)", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        // A miss: exit 64, the looked-for path on stderr.
        let miss = try runBrew(["outdated", "--json=v2"], root: root)
        #expect(miss.status == 64)
        #expect(miss.stderr.contains("no fixture"))
        #expect(miss.stderr.contains("outdated_--json=v2.stdout"))

        // A hit: fixture stdout verbatim, exit 0 by default.
        try fixture("list_--formula_--versions.stdout", "")
        let empty = try runBrew(["list", "--formula", "--versions"], root: root)
        #expect(empty.status == 0)
        #expect(empty.stdout.isEmpty)

        // A successful mutation copies .apply/ into the overlay, which wins the next lookup.
        try fixture("install_--formula_wget2.stdout", "==> Pouring wget2\n")
        try fixture("install_--formula_wget2.apply/list_--formula_--versions.stdout",
                    "wget2 2.2.0\n")
        let install = try runBrew(["install", "--formula", "wget2"], root: root)
        #expect(install.status == 0)
        #expect(install.stdout == "==> Pouring wget2\n")
        let after = try runBrew(["list", "--formula", "--versions"], root: root)
        #expect(after.stdout == "wget2 2.2.0\n")

        // A failed mutation applies nothing.
        try fixture("uninstall_--formula_bat.exitcode", "1")
        try fixture("uninstall_--formula_bat.stderr", "Error: refusing\n")
        try fixture("uninstall_--formula_bat.apply/marker.stdout", "must not land")
        let failed = try runBrew(["uninstall", "--formula", "bat"], root: root)
        #expect(failed.status == 1)
        #expect(failed.stderr == "Error: refusing\n")
        let marker = root.appending(path: "brew-state/marker.stdout", directoryHint: .notDirectory)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // A .delay holds the answer (how UI tests pin mid-command states) — and a .delay
        // alone is still a missing fixture, not an answer.
        try fixture("update.stdout", "Already up-to-date.\n")
        try fixture("update.delay", "1")
        let held = ContinuousClock.now
        let update = try runBrew(["update"], root: root)
        #expect(ContinuousClock.now - held >= .seconds(1))
        #expect(update.stdout == "Already up-to-date.\n")
        try fixture("upgrade.delay", "1")
        let delayOnly = try runBrew(["upgrade"], root: root)
        #expect(delayOnly.status == 64)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "UITestModeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let brew = root.appending(path: "prefix/bin/brew", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: brew.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(UITestMode.fakeBrewScript.utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: brew.path)
        return root
    }

    private func runBrew(_ arguments: [String], root: URL) throws
        -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = root.appending(path: "prefix/bin/brew", directoryHint: .notDirectory)
        process.arguments = arguments
        // The script needs cat/mkdir/cp; in the app the child inherits the full environment.
        process.environment = ["BREWERY_UITEST_ROOT": root.path, "PATH": "/bin:/usr/bin"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, out, err)
    }
}
