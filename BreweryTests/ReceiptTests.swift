//
//  ReceiptTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("INSTALL_RECEIPT.json parsing")
struct ReceiptParsingTests {

    /// Shape of a real `Cellar/<name>/<version>/INSTALL_RECEIPT.json`, unused keys included on
    /// purpose: the parser must ignore everything it does not declare. One dependency is
    /// tap-qualified and the `declared_directly` entries sit in the middle of the array.
    private static let formulaReceipt = """
        {
          "homebrew_version": "6.0.4",
          "used_options": [],
          "unused_options": [],
          "built_as_bottle": true,
          "poured_from_bottle": true,
          "loaded_from_api": true,
          "installed_as_dependency": false,
          "installed_on_request": true,
          "changed_files": ["INSTALL_RECEIPT.json", "bin/wget"],
          "time": 1770000000,
          "source_modified_time": 1732000000,
          "compiler": "clang",
          "aliases": [],
          "runtime_dependencies": [
            {
              "full_name": "libunistring",
              "version": "1.3",
              "revision": 0,
              "pkg_version": "1.3",
              "declared_directly": false
            },
            {
              "full_name": "gettext",
              "version": "0.25",
              "revision": 0,
              "pkg_version": "0.25",
              "declared_directly": false
            },
            {
              "full_name": "libidn2",
              "version": "2.3.8",
              "revision": 0,
              "pkg_version": "2.3.8",
              "declared_directly": true
            },
            {
              "full_name": "acme/tap/openssl@3",
              "version": "3.5.1",
              "revision": 0,
              "pkg_version": "3.5.1",
              "declared_directly": true
            },
            {
              "full_name": "ca-certificates",
              "version": "2025-05-20",
              "revision": 0,
              "pkg_version": "2025-05-20",
              "declared_directly": false
            }
          ],
          "source": {
            "spec": "stable",
            "versions": { "stable": "1.25.0", "head": null, "version_scheme": 0 },
            "path": "/opt/homebrew/Library/Taps/homebrew/homebrew-core/Formula/w/wget.rb",
            "tap": "homebrew/core",
            "tap_git_head": "8bd7e6bd07dbbb0b02b0c5c1a9b78b1e0f5a6c11"
          },
          "arch": "arm64",
          "built_on": {
            "os": "Macintosh",
            "os_version": "macOS 26.0",
            "cpu_family": "arm_firestorm_icestorm",
            "xcode": "26.0",
            "clt": "26.0.0.0.1.1745555555"
          }
        }
        """

    /// A keg that arrived as somebody else's dependency (`abseil`, verified live).
    private static let dependencyReceipt = """
        {
          "homebrew_version": "6.0.4",
          "installed_as_dependency": true,
          "installed_on_request": false,
          "poured_from_bottle": true,
          "loaded_from_api": true,
          "time": 1770000000,
          "runtime_dependencies": [],
          "source": {
            "spec": "stable",
            "versions": { "stable": "20250512.1", "head": null, "version_scheme": 0 },
            "tap": "homebrew/core"
          },
          "arch": "arm64"
        }
        """

    /// An older receipt that predates the flag: brew's `tab.rb` reads an absent
    /// `installed_on_request` as `false`. `runtime_dependencies` is absent too.
    private static let flaglessReceipt = """
        {
          "homebrew_version": "1.7.6",
          "used_options": [],
          "unused_options": [],
          "built_as_bottle": true,
          "poured_from_bottle": true,
          "time": 1500000000,
          "source": { "spec": "stable", "tap": "homebrew/core" }
        }
        """

    /// Shape of a real `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json`: same
    /// `installed_on_request` key, but `runtime_dependencies` is an OBJECT, not an array.
    private static let caskReceipt = """
        {
          "homebrew_version": "6.0.4",
          "loaded_from_api": true,
          "installed_as_dependency": false,
          "installed_on_request": true,
          "time": 1770000000,
          "runtime_dependencies": {},
          "source": {
            "path": "/opt/homebrew/Library/Taps/homebrew/homebrew-cask/Casks/i/iterm2.rb",
            "tap": "homebrew/cask",
            "tap_git_head": "3f2b6d4c9a1e5c7b8d0f2a4e6c8b0d2f4a6c8e01",
            "version": "3.5.11"
          },
          "arch": "arm64",
          "uninstall_artifacts": [
            { "quit": "com.googlecode.iterm2" },
            { "trash": ["~/Library/Preferences/com.googlecode.iterm2.plist"] }
          ]
        }
        """

    @Test("installed_on_request: true, with the full dependency closure")
    func onRequestFormula() {
        let receipt = Receipts.parse(Data(Self.formulaReceipt.utf8))

        #expect(receipt.onRequest)
        // declared_directly first in receipt order, then the rest in receipt order;
        // "acme/tap/openssl@3" normalizes to its short name.
        #expect(receipt.dependencies == ["libidn2", "openssl@3", "libunistring", "gettext", "ca-certificates"])
        // A core source.tap folds to nil — otherwise every core upgrade would get qualified.
        #expect(receipt.tap == nil)
    }

    @Test("a third-party source.tap survives; core and absent fold to nil")
    func receiptTap() {
        let tapped = """
            {"installed_on_request": true,
             "source": {"tap": "charmbracelet/tap", "path": "/opt/homebrew/Library/Taps/charmbracelet/homebrew-tap/crush.rb"}}
            """
        #expect(Receipts.parse(Data(tapped.utf8)).tap == "charmbracelet/tap")

        let cask = Receipts.parse(Data(Self.caskReceipt.utf8))
        #expect(cask.tap == nil)   // "homebrew/cask" in the fixture

        let sourceless = Receipts.parse(Data(#"{"installed_on_request": true}"#.utf8))
        #expect(sourceless.tap == nil)
    }

    @Test("installed_on_request: false for a keg pulled in as a dependency")
    func dependencyFormula() {
        let receipt = Receipts.parse(Data(Self.dependencyReceipt.utf8))

        #expect(receipt.onRequest == false)
        #expect(receipt.dependencies.isEmpty)
    }

    @Test("an absent installed_on_request inside a receipt means false")
    func absentFlag() {
        let receipt = Receipts.parse(Data(Self.flaglessReceipt.utf8))

        #expect(receipt.onRequest == false)
        #expect(receipt.dependencies.isEmpty)
        // The two "absent" cases are deliberately different: an existing receipt without the flag
        // is not the same as no receipt at all.
        #expect(receipt != Receipts.missing)
    }

    @Test("object-shaped runtime_dependencies decodes without error and yields no deps")
    func caskShape() {
        let receipt = Receipts.parse(Data(Self.caskReceipt.utf8))

        // A throw here would silently blank out every installed cask.
        #expect(receipt.onRequest)
        #expect(receipt.dependencies.isEmpty)

        // The fallback must survive a non-empty object too, not just `{}`.
        let populated = """
            {"installed_on_request": false, "runtime_dependencies": {"cask": ["font-hack-nerd-font"]}}
            """
        let other = Receipts.parse(Data(populated.utf8))
        #expect(other.onRequest == false)
        #expect(other.dependencies.isEmpty)
    }

    @Test("a missing or unreadable receipt stays visible")
    func missingDefault() {
        #expect(Receipts.missing == Receipt(onRequest: true, dependencies: []))
        // Bytes we cannot decode taught us nothing, so they degrade to the same default.
        #expect(Receipts.parse(Data("not json".utf8)) == Receipts.missing)
        #expect(Receipts.parse(Data()) == Receipts.missing)
    }
}

@Suite("Dependents inversion")
struct DependentsInversionTests {

    /// Two formulae sharing a dependency, plus a cask that has none.
    private static let installed: [Package.ID: InstalledInfo] = [
        "formula:wget": InstalledInfo(versions: ["1.25.0"],
                                      onRequest: true,
                                      dependencies: ["libidn2", "ca-certificates"]),
        "formula:curl": InstalledInfo(versions: ["8.15.0"],
                                      onRequest: true,
                                      dependencies: ["ca-certificates"]),
        "cask:iterm2": InstalledInfo(versions: ["3.5.11"], onRequest: true, dependencies: []),
    ]

    @Test("who requires what, sorted and merged across dependents")
    func invert() {
        let dependents = Receipts.invertDependents(Self.installed)

        #expect(dependents.count == 2)
        #expect(dependents["formula:ca-certificates"] == ["formula:curl", "formula:wget"])
        #expect(dependents["formula:libidn2"] == ["formula:wget"])
        // Dependency keys are always formula IDs, matching the join rule.
        #expect(dependents["cask:ca-certificates"] == nil)
        // Nothing depends on these.
        #expect(dependents["formula:wget"] == nil)
        #expect(dependents["cask:iterm2"] == nil)
    }

    @Test("no dependencies anywhere means no entries")
    func emptyInput() {
        #expect(Receipts.invertDependents([:]).isEmpty)
        #expect(Receipts.invertDependents(["formula:jq": InstalledInfo(versions: ["1.8.1"])]).isEmpty)
    }
}

@Suite("Cask app artifacts")
struct CaskAppTests {

    /// The real shape: a heterogeneous array where only some entries are `app`, and some sibling
    /// entries mix strings with objects.
    private static let caskReceipt = """
    {
      "installed_on_request": true,
      "runtime_dependencies": {},
      "uninstall_artifacts": [
        {"quit": "org.mozilla.firefox"},
        {"app": ["Firefox.app"]},
        {"binary": ["/opt/homebrew/Caskroom/firefox/1/firefox.wrapper.sh", {"target": "firefox"}]},
        {"zap": [{"trash": ["~/Library/Caches/Firefox"]}]}
      ]
    }
    """

    @Test("app bundles are picked out of the artifact list")
    func extractsApps() {
        let receipt = Receipts.parse(Data(Self.caskReceipt.utf8))
        #expect(receipt.apps == ["Firefox.app"])
        #expect(receipt.onRequest)
        #expect(receipt.dependencies.isEmpty)
    }

    @Test("a cask installing several bundles reports all of them")
    func extractsSeveralApps() {
        let json = """
        {"uninstall_artifacts": [{"app": ["Xcode.app", "Instruments.app"]}, {"app": ["Extra.app"]}]}
        """
        #expect(Receipts.parse(Data(json.utf8)).apps == ["Xcode.app", "Instruments.app", "Extra.app"])
    }

    @Test("a formula receipt names no apps")
    func formulaHasNoApps() {
        let json = """
        {"installed_on_request": true, "runtime_dependencies": [{"full_name": "gettext"}]}
        """
        let receipt = Receipts.parse(Data(json.utf8))
        #expect(receipt.apps.isEmpty)
        #expect(receipt.dependencies == ["gettext"])
    }

    /// An artifact list in an unexpected shape must not cost us the rest of the receipt — losing
    /// `installed_on_request` would move the package between Installed's scopes.
    @Test("an unexpected artifact shape yields no apps and keeps the rest")
    func toleratesUnexpectedShape() {
        let json = """
        {"installed_on_request": false, "uninstall_artifacts": [{"app": "NotAnArray.app"}]}
        """
        let receipt = Receipts.parse(Data(json.utf8))
        #expect(receipt.apps.isEmpty)
        #expect(receipt.onRequest == false)
    }

    // MARK: - Zap availability

    @Test("a zap stanza in the artifacts sets hasZap")
    func zapPresence() {
        // The Firefox-shaped fixture above carries {"zap": [...]} among its artifacts.
        #expect(Receipts.parse(Data(Self.caskReceipt.utf8)).hasZap)

        // Font casks ship uninstall artifacts but no zap stanza (font-arial, verified live).
        let font = """
        {"installed_on_request": true, "uninstall_artifacts": [{"font": ["ttf/Arial.ttf"]}]}
        """
        #expect(Receipts.parse(Data(font.utf8)).hasZap == false)

        // No artifact list at all — every formula receipt.
        let formula = """
        {"installed_on_request": true, "runtime_dependencies": [{"full_name": "gettext"}]}
        """
        #expect(Receipts.parse(Data(formula.utf8)).hasZap == false)
    }

    // MARK: - Orphans

    private static func dep(_ deps: [String] = []) -> InstalledInfo {
        InstalledInfo(versions: ["1.0"], onRequest: false, dependencies: deps)
    }

    /// The fixpoint matches `brew autoremove` (`utils/autoremove.rb`): direct orphans go,
    /// and so does what only they were keeping alive — round after round until stable.
    /// On-request packages, from-source builds and anything a survivor needs all stay.
    @Test("orphans fall to the autoremove fixpoint")
    func orphanFixpoint() {
        let installed: [Package.ID: InstalledInfo] = [
            "formula:app": InstalledInfo(versions: ["1.0"], onRequest: true, dependencies: ["lib"]),
            "formula:lib": Self.dep(["sublib"]),      // kept by app
            "formula:sublib": Self.dep(),             // kept by lib
            "formula:stray": Self.dep(["straylib"]),  // orphan — nothing needs it
            "formula:straylib": Self.dep(),           // orphaned the round after stray falls
            "cask:tool": Self.dep(),                  // casks are never orphans
        ]
        #expect(Receipts.orphans(in: installed) == ["formula:stray", "formula:straylib"])

        // A cask's depends_on formulae (from the catalog — cask receipts carry no deps)
        // hold formulae alive, transitively: the neovide → neovim → lpeg shape.
        let caskHeld: [Package.ID: InstalledInfo] = [
            "cask:neovide": InstalledInfo(versions: ["1.0"], onRequest: true),
            "formula:neovim": Self.dep(["lpeg"]),
            "formula:lpeg": Self.dep(),
        ]
        #expect(Receipts.orphans(in: caskHeld,
                                 caskDependencies: ["cask:neovide": ["neovim"]]).isEmpty)
        // Without the cask's claim the whole chain falls.
        #expect(Receipts.orphans(in: caskHeld) == ["formula:neovim", "formula:lpeg"])

        // brew only autoremoves bottles: a from-source build never falls.
        let fromSource: [Package.ID: InstalledInfo] = [
            "formula:handmade": InstalledInfo(versions: ["1.0"], onRequest: false,
                                              builtFromSource: true),
        ]
        #expect(Receipts.orphans(in: fromSource).isEmpty)

        // Nothing installed on request ever falls.
        let requested: [Package.ID: InstalledInfo] = [
            "formula:solo": InstalledInfo(versions: ["1.0"], onRequest: true),
        ]
        #expect(Receipts.orphans(in: requested).isEmpty)
    }
}
