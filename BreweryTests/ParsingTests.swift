//
//  ParsingTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("brew list --versions")
struct ListVersionsParsingTests {

    @Test("one version per line")
    func normalLines() {
        let output = """
            aria2 1.37.0
            jq 1.7.1
            wget 1.25.0
            """

        let installed = BrewClient.parseListVersions(output, kind: .formula)
        #expect(installed.count == 3)
        #expect(installed["formula:aria2"] == InstalledInfo(versions: ["1.37.0"]))
        #expect(installed["formula:jq"] == InstalledInfo(versions: ["1.7.1"]))
        #expect(installed["formula:wget"] == InstalledInfo(versions: ["1.25.0"]))
        #expect(installed["cask:wget"] == nil)
    }

    @Test("casks are keyed by their token")
    func caskKind() {
        let installed = BrewClient.parseListVersions("iterm2 3.5.11\nrectangle 0.86", kind: .cask)
        #expect(installed.count == 2)
        #expect(installed["cask:iterm2"] == InstalledInfo(versions: ["3.5.11"]))
        #expect(installed["cask:rectangle"] == InstalledInfo(versions: ["0.86"]))
    }

    @Test("several kegs of the same formula")
    func multipleVersions() {
        let installed = BrewClient.parseListVersions("python@3.12 3.12.1 3.12.4\nwget 1.25.0", kind: .formula)
        #expect(installed.count == 2)
        #expect(installed["formula:python@3.12"] == InstalledInfo(versions: ["3.12.1", "3.12.4"]))
        #expect(installed["formula:wget"] == InstalledInfo(versions: ["1.25.0"]))
    }

    @Test("empty output")
    func emptyOutput() {
        #expect(BrewClient.parseListVersions("", kind: .formula).isEmpty)
        #expect(BrewClient.parseListVersions("\n\n", kind: .cask).isEmpty)
    }

    @Test("trailing newline, blank lines and padding")
    func whitespaceTolerance() {
        let output = "\nwget   1.25.0\n\njq 1.7.1\n"
        let installed = BrewClient.parseListVersions(output, kind: .formula)
        #expect(installed.count == 2)
        #expect(installed["formula:wget"] == InstalledInfo(versions: ["1.25.0"]))
        #expect(installed["formula:jq"] == InstalledInfo(versions: ["1.7.1"]))
    }

    @Test("tap-qualified names normalize to the keg name")
    func shortNameJoin() {
        let installed = BrewClient.parseListVersions("acme/tap/widget 2.0", kind: .formula)
        #expect(installed["formula:widget"] == InstalledInfo(versions: ["2.0"]))
        #expect(BrewClient.shortName("acme/tap/widget") == "widget")
        #expect(BrewClient.shortName("wget") == "wget")
    }
}

@Suite("brew outdated --json=v2")
struct OutdatedParsingTests {

    /// Shape of a real `brew outdated --json=v2` payload: formulae (one tap-qualified, one pinned)
    /// plus casks.
    private static let fixture = """
        {
          "formulae": [
            {
              "name": "wget",
              "installed_versions": ["1.24.5"],
              "current_version": "1.25.0",
              "pinned": false,
              "pinned_version": null
            },
            {
              "name": "acme/tap/node",
              "installed_versions": ["20.11.0"],
              "current_version": "22.3.0",
              "pinned": true,
              "pinned_version": "20.11.0"
            }
          ],
          "casks": [
            {
              "name": "iterm2",
              "installed_versions": ["3.5.10"],
              "current_version": "3.5.11"
            }
          ]
        }
        """

    @Test("formulae and casks, including a pinned entry")
    func fullPayload() throws {
        let outdated = try BrewClient.parseOutdated(Data(Self.fixture.utf8))

        #expect(outdated.count == 3)
        #expect(outdated["formula:wget"] == OutdatedInfo(installed: ["1.24.5"], current: "1.25.0", pinned: false))
        // Tap-qualified names are normalized so the key matches Package.ID.
        #expect(outdated["formula:acme/tap/node"] == nil)
        #expect(outdated["formula:node"] == OutdatedInfo(installed: ["20.11.0"], current: "22.3.0", pinned: true))
        // Casks carry no "pinned" key; it must default to false rather than fail the decode.
        #expect(outdated["cask:iterm2"] == OutdatedInfo(installed: ["3.5.10"], current: "3.5.11", pinned: false))
    }

    @Test("empty arrays")
    func emptyArrays() throws {
        #expect(try BrewClient.parseOutdated(Data(#"{"formulae":[],"casks":[]}"#.utf8)).isEmpty)
    }

    @Test("stderr noise around the JSON object is ignored")
    func surroundingNoise() throws {
        let noisy = """
            Warning: Treating wget as a formula.
            {"formulae":[{"name":"wget","installed_versions":["1.24.5"],"current_version":"1.25.0","pinned":false}],"casks":[]}
            """
        let outdated = try BrewClient.parseOutdated(Data(noisy.utf8))
        #expect(outdated["formula:wget"] == OutdatedInfo(installed: ["1.24.5"], current: "1.25.0", pinned: false))
    }

    @Test("malformed payload throws")
    func malformedPayload() {
        #expect(throws: (any Error).self) {
            try BrewClient.parseOutdated(Data("not json".utf8))
        }
    }
}

@Suite("Catalog slim decoding")
struct CatalogDecodingTests {

    /// Copied from a real `formula.json` entry, unused keys included on purpose: the slim decoder
    /// must ignore everything it does not declare.
    private static let formulaJSON = """
        [
          {
            "name": "wget",
            "full_name": "wget",
            "tap": "homebrew/core",
            "oldnames": [],
            "aliases": [],
            "versioned_formulae": [],
            "desc": "Internet file retriever",
            "license": "GPL-3.0-or-later",
            "homepage": "https://www.gnu.org/software/wget/",
            "versions": { "stable": "1.25.0", "head": "HEAD", "bottle": true },
            "urls": {
              "stable": {
                "url": "https://ftp.gnu.org/gnu/wget/wget-1.25.0.tar.gz",
                "tag": null,
                "revision": null,
                "checksum": "766e48423e79359ea31e41db9e5c289675947a7fcf2efdcedb726ac9d0da3784"
              }
            },
            "revision": 0,
            "version_scheme": 0,
            "bottle": {
              "stable": {
                "rebuild": 0,
                "root_url": "https://ghcr.io/v2/homebrew/core",
                "files": { "arm64_sequoia": { "cellar": ":any", "url": "https://example.invalid" } }
              }
            },
            "keg_only": false,
            "keg_only_reason": null,
            "dependencies": ["libidn2", "openssl@3"],
            "requirements": [],
            "conflicts_with": [],
            "deprecated": false,
            "deprecation_date": null,
            "deprecation_reason": null,
            "disabled": false,
            "disable_date": null,
            "ruby_source_path": "Formula/w/wget.rb"
          },
          {
            "name": "libfoo",
            "desc": null,
            "homepage": null,
            "versions": { "stable": "0.9", "head": null, "bottle": false },
            "deprecated": true,
            "disabled": true
          },
          {
            "name": "headonly",
            "desc": "Only ever built from HEAD",
            "homepage": "https://example.com",
            "versions": { "stable": null, "head": "HEAD", "bottle": false }
          }
        ]
        """

    /// Copied from a real `cask.json` entry, likewise with the unused keys left in.
    private static let caskJSON = """
        [
          {
            "token": "visual-studio-code",
            "full_token": "visual-studio-code",
            "old_tokens": [],
            "tap": "homebrew/cask",
            "name": ["Microsoft Visual Studio Code", "VS Code"],
            "desc": "Open-source code editor",
            "homepage": "https://code.visualstudio.com/",
            "url": "https://update.code.visualstudio.com/1.96.2/darwin-universal/stable",
            "version": "1.96.2",
            "sha256": "no_check",
            "artifacts": [{ "app": ["Visual Studio Code.app"] }, { "zap": [{ "trash": ["~/Library/Caches/com.microsoft.VSCode"] }] }],
            "depends_on": { "macos": { ">=": ["11"] } },
            "conflicts_with": null,
            "caveats": null,
            "auto_updates": true,
            "deprecated": false,
            "deprecation_date": null,
            "disabled": false,
            "ruby_source_path": "Casks/v/visual-studio-code.rb"
          },
          {
            "token": "mystery-app",
            "name": [],
            "desc": null,
            "homepage": null,
            "deprecated": true,
            "disabled": true
          }
        ]
        """

    @Test("formulae: unknown keys ignored, null desc/homepage fine")
    func decodeFormulae() throws {
        let packages = try CatalogStore.decodeFormulae(Data(Self.formulaJSON.utf8))
        #expect(packages.count == 3)

        let wget = try #require(packages.first)
        #expect(wget.kind == .formula)
        #expect(wget.name == "wget")
        #expect(wget.displayName == nil)
        #expect(wget.title == "wget")
        #expect(wget.desc == "Internet file retriever")
        #expect(wget.homepage == "https://www.gnu.org/software/wget/")
        #expect(wget.version == "1.25.0")
        #expect(wget.deprecated == false)
        #expect(wget.disabled == false)
        #expect(wget.id == "formula:wget")

        let libfoo = packages[1]
        #expect(libfoo.desc == nil)
        #expect(libfoo.homepage == nil)
        #expect(libfoo.homepageURL == nil)
        #expect(libfoo.iconURL == nil)
        #expect(libfoo.version == "0.9")
        #expect(libfoo.deprecated)
        #expect(libfoo.disabled)

        // Missing flags default to false; a null stable version becomes "".
        let headonly = packages[2]
        #expect(headonly.version == "")
        #expect(headonly.deprecated == false)
        #expect(headonly.disabled == false)
    }

    @Test("casks: display name is the first name entry")
    func decodeCasks() throws {
        let packages = try CatalogStore.decodeCasks(Data(Self.caskJSON.utf8))
        #expect(packages.count == 2)

        let vscode = try #require(packages.first)
        #expect(vscode.kind == .cask)
        #expect(vscode.name == "visual-studio-code")
        #expect(vscode.displayName == "Microsoft Visual Studio Code")
        #expect(vscode.title == "Microsoft Visual Studio Code")
        #expect(vscode.desc == "Open-source code editor")
        #expect(vscode.version == "1.96.2")
        #expect(vscode.deprecated == false)
        #expect(vscode.disabled == false)
        #expect(vscode.id == "cask:visual-studio-code")
        #expect(vscode.iconURL == URL(string: "https://icons.duckduckgo.com/ip3/code.visualstudio.com.ico"))

        let mystery = packages[1]
        #expect(mystery.displayName == nil)
        #expect(mystery.title == "mystery-app")
        #expect(mystery.desc == nil)
        #expect(mystery.homepage == nil)
        #expect(mystery.version == "")       // missing version
        #expect(mystery.deprecated)
        #expect(mystery.disabled)
    }

    @Test("cask comma-versions truncate for display")
    func shortVersion() {
        #expect("2.1.50,56f0a83".shortVersion == "2.1.50")
        #expect("1.25.0".shortVersion == "1.25.0")
        #expect("".shortVersion == "")
    }

    /// The on-disk cache is written with a stock `JSONEncoder`, so the round-trip uses stock coders too.
    @Test("the cache round-trips")
    func cacheRoundTrip() throws {
        let cache = CatalogCache(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 packages: try CatalogStore.decodeCasks(Data(Self.caskJSON.utf8)))

        let restored = try JSONDecoder().decode(CatalogCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.packages == cache.packages)
        #expect(restored.fetchedAt == cache.fetchedAt)
        #expect(CatalogStore.isStale(restored.fetchedAt))
        #expect(!CatalogStore.isStale(.now))
    }
}
