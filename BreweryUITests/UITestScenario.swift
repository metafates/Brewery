//
//  UITestScenario.swift
//  BreweryUITests
//
//  Created by vzbarashchenko on 23.08.2026.
//
//  The deterministic harness's test side. A scenario describes a world — packages, brew
//  command outcomes, HTTP deviations — and `launch(in:)` ships it to the app as one
//  compressed launch-environment payload (`Brewery/UITestMode.swift` is the receiving side;
//  `UITestModeTests` pins the wire format, since no source file is shared between targets).
//  The runner only *names* the fixture root; the app creates every directory and writes every
//  byte, fake brew included — a runner-written file may be unreadable or unexecutable by the
//  app process (learned upstream: Homebrew's BrewUI hit EPERM exactly there). The root lives
//  under /tmp, not the runner's per-process temp container, for the same reason.
//

import Foundation
import XCTest

/// One package description rendered into every wire format at once — the catalog entry, the
/// `list --versions` line and the `outdated --json=v2` entry can never disagree.
struct FixturePackage {
    enum Kind { case formula, cask }
    var name: String
    var kind: Kind = .formula
    var desc: String = "A fixture package"
    var version: String
    var installedVersions: [String] = []
    var outdated: Bool = false

    fileprivate var catalogEntry: [String: Any] {
        switch kind {
        case .formula:
            ["name": name, "desc": desc, "homepage": "https://example.org/\(name)",
             "versions": ["stable": version]]
        case .cask:
            ["token": name, "name": [name], "desc": desc,
             "homepage": "https://example.org/\(name)", "version": version]
        }
    }

    fileprivate var outdatedEntry: [String: Any] {
        ["name": name, "installed_versions": installedVersions,
         "current_version": version, "pinned": false]
    }
}

struct Scenario {
    var packages: [FixturePackage] = []
    var brewInstalled = true
    /// When set, every base HTTP fixture gains this `.etag` sibling, so a relaunch against a
    /// stale cache exercises the conditional-request branch end to end (the stub answers a
    /// matching `If-None-Match` with a real 304).
    var etag: String?
    private var extraFiles: [String: Data] = [:]

    init(packages: [FixturePackage] = [], brewInstalled: Bool = true, etag: String? = nil) {
        self.packages = packages
        self.brewInstalled = brewInstalled
        self.etag = etag
    }

    /// A brew invocation's outcome. `after` re-renders the four probe stdouts into the
    /// command's `.apply/` tree from the same renderer as the base world — on success the fake
    /// copies them into its state overlay, and the app's own post-mutation reconcile sees the
    /// changed world. Consistency by construction, both before and after.
    mutating func brewCommand(_ argv: [String], stdout: String = "", stderr: String = "",
                              exitCode: Int = 0, delay: Int? = nil,
                              after: [FixturePackage]? = nil) {
        let key = argv.joined(separator: "_")
        extraFiles["brew/\(key).stdout"] = Data(stdout.utf8)
        if !stderr.isEmpty { extraFiles["brew/\(key).stderr"] = Data(stderr.utf8) }
        if exitCode != 0 { extraFiles["brew/\(key).exitcode"] = Data("\(exitCode)".utf8) }
        // Seconds the fake sleeps before answering — how a test holds the "command running"
        // state long enough to assert what the UI does during it.
        if let delay { extraFiles["brew/\(key).delay"] = Data("\(delay)".utf8) }
        if let after {
            for (name, contents) in Self.probeFiles(for: after) {
                extraFiles["brew/\(key).apply/\(name)"] = contents
            }
        }
    }

    /// Replaces one endpoint's answer: body always, `.status` when it should not be a 200.
    mutating func httpOverride(path: String, body: Data, status: Int? = nil) {
        let key = path.split(separator: "/").joined(separator: "_")
        extraFiles["http/\(key)"] = body
        if let status { extraFiles["http/\(key).status"] = Data("\(status)".utf8) }
    }

    mutating func seedFile(_ relativePath: String, _ contents: Data) {
        extraFiles[relativePath] = contents
    }

    /// Assembles the payload, launches the app against it, and registers teardown (terminate +
    /// root removal). `root` is stable per scenario value, so a second `launch` in one test —
    /// the relaunch shape — reinstalls fixtures into the same root while app-written state
    /// (the catalog cache under `support/`) survives.
    @discardableResult
    func launch(in test: XCTestCase, root: URL? = nil) -> XCUIApplication {
        let root = root ?? Self.makeRoot()
        var files = baseFiles()
        // Extras land last: a scenario's override beats any rendered default.
        files.merge(extraFiles) { _, override in override }

        let encoded: String
        do {
            encoded = try Self.encodePayload(files: files, installBrew: brewInstalled)
        } catch {
            XCTFail("Scenario payload failed to encode: \(error)")
            return XCUIApplication()
        }
        if encoded.count > 256 * 1024 {
            let largest = files.sorted { $0.value.count > $1.value.count }.prefix(3)
                .map { "\($0.key): \($0.value.count) bytes" }
            XCTFail("""
            Scenario payload is \(encoded.count) bytes encoded — over the 256 KB budget. The
            environment is shared with everything else the launch needs: shrink the scenario
            rather than raising the limit. Largest fixtures: \(largest.joined(separator: ", "))
            """)
            return XCUIApplication()
        }

        let app = XCUIApplication()
        app.launchArguments = UITestSeed.pinnedState
        app.launchEnvironment = [
            "BREWERY_UITEST_PAYLOAD": encoded,
            "BREWERY_UITEST_ROOT": root.path,
            // Plain environment siblings under the root: the login-shell overlay is empty
            // under the harness, so these reach the app's resolution paths and its brew
            // children unshadowed.
            "XDG_CONFIG_HOME": root.appending(path: "config").path,
            "HOMEBREW_CACHE": root.appending(path: "cache").path,
            "HOMEBREW_LOGS": root.appending(path: "logs").path,
        ]
        test.addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        return app
    }

    /// The app creates everything inside; the runner never writes here. Under /tmp, not the
    /// runner's temp container, so the app executes only files it owns in a directory the OS
    /// does not scope to another process.
    static func makeRoot() -> URL {
        URL(filePath: "/tmp", directoryHint: .isDirectory)
            .appending(path: "BreweryUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: - Rendering

    /// Every scenario answers the whole read-only surface — a missing fixture would surface as
    /// an unrelated error state somewhere else in the UI.
    private func baseFiles() -> [String: Data] {
        var files: [String: Data] = [:]
        files["http/api_formula.json"] =
            Self.json(packages.filter { $0.kind == .formula }.map(\.catalogEntry))
        files["http/api_cask.json"] =
            Self.json(packages.filter { $0.kind == .cask }.map(\.catalogEntry))
        files["http/api_internal_executables.txt"] = Data()
        files["http/api_analytics_install_90d.json"] = Self.json(["items": [[String: Any]]()])
        files["http/api_analytics_cask-install_homebrew-cask_90d.json"] =
            Self.json(["formulae": [String: Any]()])
        if let etag {
            for key in files.keys where key.hasPrefix("http/") {
                files["\(key).etag"] = Data(etag.utf8)
            }
        }
        for (name, contents) in Self.probeFiles(for: packages) {
            files["brew/\(name)"] = contents
        }
        files["brew/update.stdout"] = Data("Already up-to-date.\n".utf8)
        files["config/homebrew/trust.json"] = Data("{}".utf8)
        return files
    }

    /// The four read probes `refreshState()` runs, rendered from one package list.
    private static func probeFiles(for packages: [FixturePackage]) -> [String: Data] {
        func listLines(_ kind: FixturePackage.Kind) -> Data {
            let lines = packages
                .filter { $0.kind == kind && !$0.installedVersions.isEmpty }
                .map { "\($0.name) \($0.installedVersions.joined(separator: " "))" }
            return Data(lines.map { $0 + "\n" }.joined().utf8)
        }
        let outdated = json([
            "formulae": packages.filter { $0.kind == .formula && $0.outdated }.map(\.outdatedEntry),
            "casks": packages.filter { $0.kind == .cask && $0.outdated }.map(\.outdatedEntry),
        ])
        return [
            "list_--formula_--versions.stdout": listLines(.formula),
            "list_--cask_--versions.stdout": listLines(.cask),
            "outdated_--json=v2.stdout": outdated,
            "services_list_--json.stdout": Data("[]".utf8),
        ]
    }

    /// Fixtures are authored as dictionaries; an unserializable value is a test-authoring bug
    /// and should die here, at the call site, not as an opaque decode error inside the app.
    private static func json(_ object: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            preconditionFailure("Fixture is not serializable JSON: \(object)")
        }
        return data
    }

    /// The wire format `UITestModeTests.pinnedWireFormat` pins on the app side:
    /// base64(zlib(JSON{files, installBrew})).
    private static func encodePayload(files: [String: Data], installBrew: Bool) throws -> String {
        struct Payload: Encodable {
            var files: [String: Data]
            var installBrew: Bool
        }
        let json = try JSONEncoder().encode(Payload(files: files, installBrew: installBrew))
        let compressed = try (json as NSData).compressed(using: .zlib)
        return (compressed as Data).base64EncodedString()
    }
}
