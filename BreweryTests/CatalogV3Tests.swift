//
//  CatalogV3Tests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("executables.txt")
struct ExecutablesParsingTests {

    /// The real file is one line per formula, `name:cmd1 cmd2 …`. The imagemagick line is quoted
    /// from the live endpoint, trimmed to its first few commands.
    @Test("one line per formula, commands space-separated after the first colon")
    func normalLines() {
        let text = """
            imagemagick:Magick++-config compare composite conjure convert display
            wget:wget
            """

        let commands = CatalogStore.parseExecutables(Data(text.utf8))
        #expect(commands.count == 2)
        #expect(commands["imagemagick"] == ["Magick++-config", "compare", "composite", "conjure", "convert", "display"])
        #expect(commands["wget"] == ["wget"])
    }

    /// Only the *first* colon separates: a command may contain one (and versioned names do).
    @Test("later colons belong to the command list")
    func firstColonSplits() {
        let commands = CatalogStore.parseExecutables(Data("python@3.12:python3.12 pip3.12 2to3-3.12\n".utf8))
        #expect(commands["python@3.12"] == ["python3.12", "pip3.12", "2to3-3.12"])
    }

    @Test("empty input")
    func emptyInput() {
        #expect(CatalogStore.parseExecutables(Data()).isEmpty)
        #expect(CatalogStore.parseExecutables(Data("\n\n".utf8)).isEmpty)
    }

    /// A line the endpoint should never emit must cost that line only — never the whole file.
    @Test("malformed lines are skipped, the rest still parses")
    func malformedLines() {
        let text = """
            no-colon-at-all
            :orphaned-command
            empty-command-list:
            jq:jq
            """

        let commands = CatalogStore.parseExecutables(Data(text.utf8))
        #expect(commands.count == 1)
        #expect(commands["jq"] == ["jq"])
    }
}

@Suite("Install analytics")
struct AnalyticsParsingTests {

    /// Shape of `analytics/install/90d.json`: an `items` array whose counts are comma-formatted
    /// strings, tap-qualified names included.
    private static let formulaJSON = """
        {
          "category": "install",
          "total_items": 4,
          "start_date": "2026-05-12",
          "end_date": "2026-08-10",
          "total_count": 67000000,
          "items": [
            { "number": 1, "formula": "openssl@3", "count": "1,444,019", "percent": "2.15" },
            { "number": 2, "formula": "vim", "count": "63,157", "percent": "0.09" },
            { "number": 3, "formula": "acme/tap/widget", "count": "12", "percent": "0.00" },
            { "number": 4, "formula": "mystery", "count": "n/a", "percent": "0.00" }
          ]
        }
        """

    /// The cask file's top-level key really is `formulae` (historical misnaming) and it is a dict
    /// keyed by token, each token holding an array.
    private static let caskJSON = """
        {
          "category": "cask-install",
          "total_items": 3,
          "formulae": {
            "firefox": [{ "cask": "firefox", "count": "46,785" }],
            "iterm2": [{ "cask": "iterm2", "count": "868" }],
            "ghost-token": []
          }
        }
        """

    @Test("comma-formatted string counts")
    func counts() {
        #expect(CatalogStore.parseCount("1,444,019") == 1_444_019)
        #expect(CatalogStore.parseCount("868") == 868)
        #expect(CatalogStore.parseCount("") == nil)
        #expect(CatalogStore.parseCount("n/a") == nil)
        #expect(CatalogStore.parseCount("12.5") == nil)
    }

    @Test("formula analytics keyed by name")
    func formulaAnalytics() {
        let installs = CatalogStore.parseFormulaAnalytics(Data(Self.formulaJSON.utf8))
        #expect(installs.count == 3)
        #expect(installs["openssl@3"] == 1_444_019)
        #expect(installs["vim"] == 63_157)
        // Tap-qualified entries stay as they are: they simply never match a catalog name.
        #expect(installs["acme/tap/widget"] == 12)
        // An unparseable count drops the entry rather than defaulting it to zero.
        #expect(installs["mystery"] == nil)
    }

    @Test("cask analytics keyed by token")
    func caskAnalytics() {
        let installs = CatalogStore.parseCaskAnalytics(Data(Self.caskJSON.utf8))
        #expect(installs.count == 2)
        #expect(installs["firefox"] == 46_785)
        #expect(installs["iterm2"] == 868)
        #expect(installs["ghost-token"] == nil)
    }

    /// Analytics are best effort: a broken payload empties the field, it never throws.
    @Test("garbage payloads yield no counts")
    func garbagePayloads() {
        #expect(CatalogStore.parseFormulaAnalytics(Data("not json".utf8)).isEmpty)
        #expect(CatalogStore.parseCaskAnalytics(Data("not json".utf8)).isEmpty)
        #expect(CatalogStore.parseCaskAnalytics(Data(#"{"items":[]}"#.utf8)).isEmpty)
    }
}

@Suite("Catalog v3 fields")
struct CatalogV3Tests {

    /// `vim` as the API really returns it — three conflicts with parallel reasons — plus `php`,
    /// whose caveats embed a literal `$HOMEBREW_PREFIX`, plus `rakudo-star`, which carries `null`
    /// *elements* inside `conflicts_with_reasons` (live shape: a conflict with no stated reason).
    private static let formulaJSON = """
        [
          {
            "name": "vim",
            "desc": "Vi 'workalike' with many additional features",
            "homepage": "https://www.vim.org/",
            "versions": { "stable": "9.1.1000", "head": "HEAD", "bottle": true },
            "caveats": null,
            "conflicts_with": ["ex-vi", "macvim", "vim-classic"],
            "conflicts_with_reasons": [
              "vim and ex-vi both install vi and view binaries",
              "vim and macvim both install vi* binaries",
              "vim and vim-classic both install vi* binaries"
            ],
            "deprecated": false,
            "disabled": false
          },
          {
            "name": "php",
            "desc": "General-purpose scripting language",
            "homepage": "https://www.php.net/",
            "versions": { "stable": "8.4.3" },
            "caveats": "To enable PHP in Apache add the following to httpd.conf:\\n    LoadModule php_module $HOMEBREW_PREFIX/opt/php/lib/httpd/modules/libphp.so",
            "conflicts_with": null,
            "conflicts_with_reasons": null
          },
          {
            "name": "rakudo-star",
            "desc": "Perl 6 compiler distribution",
            "homepage": "https://rakudo.org/",
            "versions": { "stable": "2024.10" },
            "conflicts_with": ["moar", "parrot"],
            "conflicts_with_reasons": ["both install `moar` binaries", null]
          }
        ]
        """

    /// A font cask and an app cask. Cask `conflicts_with` has another shape and is not parsed.
    private static let caskJSON = """
        [
          {
            "token": "font-fira-code",
            "tap": "homebrew/cask",
            "name": ["Fira Code"],
            "desc": "Monospaced font with programming ligatures",
            "homepage": "https://github.com/tonsky/FiraCode",
            "version": "6.2",
            "conflicts_with": null,
            "caveats": null,
            "deprecated": false,
            "disabled": false
          },
          {
            "token": "firefox",
            "name": ["Mozilla Firefox"],
            "desc": "Web browser",
            "homepage": "https://www.mozilla.org/firefox/",
            "version": "141.0",
            "caveats": "Installing this cask means you have AGREED to the terms at $HOMEBREW_PREFIX/share/doc.",
            "conflicts_with": { "cask": ["firefox@developer-edition"] }
          }
        ]
        """

    // MARK: - Merge

    @Test("formulae carry caveats, conflicts, commands and installs")
    func formulaMerge() throws {
        // Eight executables — the same count a field count of vim's executables.txt line gives.
        let commands = ["vim": ["ex", "rview", "rvim", "view", "vim", "vimdiff", "vimtutor", "xxd"]]
        let packages = try CatalogStore.decodeFormulae(Data(Self.formulaJSON.utf8),
                                                       commands: commands,
                                                       installs: ["vim": 63_157])

        let vim = try #require(packages.first)
        #expect(vim.conflicts.count == 3)
        #expect(vim.conflicts.map(\.name) == ["ex-vi", "macvim", "vim-classic"])
        #expect(vim.conflicts[1].reason == "vim and macvim both install vi* binaries")
        #expect(vim.commands.count == 8)
        #expect(vim.commands.contains("vimdiff"))
        #expect(vim.installs90d == 63_157)
        #expect(vim.caveats == nil)

        // No conflicts, no commands, absent from the analytics file: every v3 field degrades quietly.
        let php = packages[1]
        #expect(php.conflicts.isEmpty)
        #expect(php.commands.isEmpty)
        #expect(php.installs90d == nil)
        #expect(php.caveats?.contains("$HOMEBREW_PREFIX") == true)

        // A null reason *element* is a reasonless conflict, not a decode failure for the whole file.
        let rakudo = packages[2]
        #expect(rakudo.conflicts == [Conflict(name: "moar", reason: "both install `moar` binaries"),
                                     Conflict(name: "parrot", reason: nil)])
    }

    @Test("casks carry caveats and installs, never conflicts or commands")
    func caskMerge() throws {
        let packages = try CatalogStore.decodeCasks(Data(Self.caskJSON.utf8),
                                                    installs: ["firefox": 46_785])

        let font = try #require(packages.first)
        #expect(font.caveats == nil)
        #expect(font.installs90d == nil)

        let firefox = packages[1]
        #expect(firefox.installs90d == 46_785)
        #expect(firefox.caveats?.hasPrefix("Installing this cask") == true)
        // The object-shaped cask `conflicts_with` is deferred: decoding it must not even be attempted.
        #expect(firefox.conflicts.isEmpty)
        #expect(firefox.commands.isEmpty)
    }

    // MARK: - Conflicts

    @Test("parallel conflict arrays zip, a length mismatch pads with nil")
    func zipConflicts() {
        let matched = CatalogStore.zipConflicts(["ex-vi", "macvim"], ["one", "two"])
        #expect(matched == [Conflict(name: "ex-vi", reason: "one"), Conflict(name: "macvim", reason: "two")])

        // Fewer reasons than names: pad, never read out of bounds.
        #expect(CatalogStore.zipConflicts(["a", "b", "c"], ["one"])
                == [Conflict(name: "a", reason: "one"),
                    Conflict(name: "b", reason: nil),
                    Conflict(name: "c", reason: nil)])

        // More reasons than names: the extras have nothing to attach to.
        #expect(CatalogStore.zipConflicts(["a"], ["one", "two"]) == [Conflict(name: "a", reason: "one")])

        // A null element flattens to no reason rather than shifting the remaining reasons.
        #expect(CatalogStore.zipConflicts(["a", "b"], [nil, "two"])
                == [Conflict(name: "a", reason: nil), Conflict(name: "b", reason: "two")])

        #expect(CatalogStore.zipConflicts(["a"], nil) == [Conflict(name: "a", reason: nil)])
        #expect(CatalogStore.zipConflicts(nil, ["one"]).isEmpty)
        #expect(CatalogStore.zipConflicts([], []).isEmpty)
    }

    // MARK: - Caveats

    @Test("caveats substitute the real prefix for $HOMEBREW_PREFIX")
    func caveatsSubstitution() throws {
        let php = try CatalogStore.decodeFormulae(Data(Self.formulaJSON.utf8))[1]

        let resolved = try #require(php.resolvedCaveats(prefix: URL(fileURLWithPath: "/opt/homebrew")))
        #expect(resolved.contains("/opt/homebrew/opt/php/lib/httpd/modules/libphp.so"))
        #expect(!resolved.contains("$HOMEBREW_PREFIX"))

        // A directory URL carries a trailing slash that would otherwise double up in the path.
        let directory = php.resolvedCaveats(prefix: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true))
        #expect(directory == resolved)

        // Without a prefix there is nothing honest to substitute, so the text stands as it is.
        #expect(php.resolvedCaveats(prefix: nil) == php.caveats)

        let vim = try CatalogStore.decodeFormulae(Data(Self.formulaJSON.utf8))[0]
        #expect(vim.resolvedCaveats(prefix: URL(fileURLWithPath: "/opt/homebrew")) == nil)
    }

    // MARK: - Cache schema

    @Test("a cache without the v3 schema stamp is treated as no cache")
    func cacheVersionMismatch() throws {
        // Bumped whenever a field joins Package (4: `license`, 5: `rubySourcePath`): an older file
        // decodes without it and would otherwise be served as if it were complete.
        #expect(CatalogStore.cacheVersion == 5)
        #expect(CatalogCache(fetchedAt: .now, packages: []).version == CatalogStore.cacheVersion)

        // What the shipped v2 file looks like: no `version` key at all, so the decode throws — which
        // is exactly the "no cache" branch `loadCache` takes.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CatalogCache.self, from: Data(#"{"fetchedAt":0,"packages":[]}"#.utf8))
        }

        // A stamped but older cache decodes fine and is rejected on the version check instead.
        let older = try JSONDecoder().decode(CatalogCache.self,
                                             from: Data(#"{"version":2,"fetchedAt":0,"packages":[]}"#.utf8))
        #expect(older.version != CatalogStore.cacheVersion)
    }

    // MARK: - Fonts

    @Test("font casks are classified by their token prefix")
    func fontClassification() throws {
        let casks = try CatalogStore.decodeCasks(Data(Self.caskJSON.utf8))
        #expect(casks[0].isFont)
        #expect(!casks[1].isFont)

        // A formula is never a font, whatever it is called.
        let fontconfig = Package(kind: .formula, name: "font-util", displayName: nil, desc: nil,
                                 homepage: nil, version: "1.4.1", deprecated: false, disabled: false)
        #expect(!fontconfig.isFont)
    }
}

@Suite("License decoding")
struct LicenseDecodingTests {

    @Test("A formula's SPDX license is carried through")
    func decodesLicense() throws {
        let json = """
        [{"name":"wget","desc":"Internet file retriever","homepage":"https://www.gnu.org/software/wget/",
          "versions":{"stable":"1.25.0"},"license":"GPL-3.0-or-later","deprecated":false,"disabled":false}]
        """.data(using: .utf8)!
        let package = try #require(try CatalogStore.decodeFormulae(json).first)
        #expect(package.license == "GPL-3.0-or-later")
        #expect(package.licenseLabel == "GPL-3.0-or-later")
    }

    /// The field is a plain string today, but it has a history of being an SPDX expression object.
    /// One surprising entry must not take the whole catalog down with it.
    @Test("An unexpected license shape decodes as nil rather than throwing")
    func toleratesUnexpectedLicenseShape() throws {
        let json = """
        [{"name":"a","versions":{"stable":"1"},"license":{"any_of":["MIT","Apache-2.0"]}},
         {"name":"b","versions":{"stable":"2"},"license":"MIT"}]
        """.data(using: .utf8)!
        let packages = try CatalogStore.decodeFormulae(json)
        #expect(packages.count == 2)
        #expect(packages[0].licenseLabel == nil)
        #expect(packages[1].licenseLabel == "MIT")
    }

    @Test("Casks carry no license")
    func casksHaveNoLicense() throws {
        let json = """
        [{"token":"iterm2","name":["iTerm2"],"version":"3.5.11","homepage":"https://iterm2.com/"}]
        """.data(using: .utf8)!
        let package = try #require(try CatalogStore.decodeCasks(json).first)
        #expect(package.licenseLabel == nil)
    }
}
