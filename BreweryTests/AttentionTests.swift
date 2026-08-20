//
//  AttentionTests.swift
//  BreweryTests
//
//  The Attention report's grammar and decode. The sentences mirror brew's own
//  `DeprecateDisable.message` (`deprecate_disable.rb`): preset slugs humanize through the
//  vendored tables, prose passes through the same "it …" frame, and a missing disable date
//  projects deprecation + 12 months (`REMOVE_DISABLED_TIME_WINDOW`).
//

import Foundation
import Testing
@testable import Brewery

struct AttentionTests {
    private func package(kind: PackageKind = .formula,
                         deprecated: Bool = false, disabled: Bool = false,
                         deprecationDate: String? = nil, deprecationReason: String? = nil,
                         disableDate: String? = nil, disableReason: String? = nil,
                         replacementFormula: String? = nil, replacementCask: String? = nil) -> Package {
        var package = Package(kind: kind, name: "thing", displayName: nil, desc: nil,
                              homepage: nil, version: "1", deprecated: deprecated, disabled: disabled)
        package.deprecationDate = deprecationDate
        package.deprecationReason = deprecationReason
        package.disableDate = disableDate
        package.disableReason = disableReason
        package.replacementFormula = replacementFormula
        package.replacementCask = replacementCask
        return package
    }

    // MARK: - Sentences

    @Test("a healthy package explains nothing")
    func healthy() {
        #expect(package().deprecationExplanation == nil)
        #expect(package().needsAttention == false)
    }

    @Test("deprecated with slug, date and an explicit disable date — the full sentence")
    func deprecatedFull() {
        let explained = package(deprecated: true,
                                deprecationDate: "2026-05-19", deprecationReason: "unsupported",
                                disableDate: "2027-05-19").deprecationExplanation
        #expect(explained == "Homebrew deprecated this package on May 19, 2026 — it is not supported upstream. "
                + "It still installs today, but is scheduled to stop working on May 19, 2027.")
    }

    @Test("no disable date projects deprecation + 12 months, phrased as around")
    func projectedDisable() {
        let explained = package(deprecated: true,
                                deprecationDate: "2026-05-19",
                                deprecationReason: "unmaintained").deprecationExplanation
        #expect(explained == "Homebrew deprecated this package on May 19, 2026 — it is not maintained upstream. "
                + "It still installs today, but will likely stop working around May 2027.")
    }

    @Test("no facts at all degrades to the generic copy")
    func bareDeprecation() {
        #expect(package(deprecated: true).deprecationExplanation
                == "Homebrew has deprecated this package. It still installs today, but it may be disabled in a future release.")
    }

    @Test("prose reasons pass through brew's own \"it …\" frame")
    func proseReason() {
        let explained = package(deprecated: true,
                                deprecationReason: "uses deprecated Python 2").deprecationExplanation
        #expect(explained?.hasPrefix("Homebrew has deprecated this package — it uses deprecated Python 2.") == true)
    }

    @Test("disabled ends the story: no longer installable")
    func disabled() {
        let explained = package(disabled: true,
                                disableDate: "2026-01-02", disableReason: "does_not_build").deprecationExplanation
        #expect(explained == "Homebrew disabled this package on January 2, 2026 — it does not build. "
                + "It can no longer be installed.")
    }

    @Test("casks humanize through the cask table")
    func caskReasons() {
        let explained = package(kind: .cask, deprecated: true,
                                deprecationReason: "moved_to_mas").deprecationExplanation
        #expect(explained?.contains("is now exclusively distributed on the Mac App Store") == true)
    }

    // MARK: - Replacement

    @Test("the replacement row prefers the formula, brew's replacement_with_type rule")
    func replacementPrefersFormula() {
        #expect(package(deprecated: true, replacementFormula: "vim", replacementCask: "macvim")
            .replacementID == "formula:vim")
        #expect(package(deprecated: true, replacementCask: "macvim").replacementID == "cask:macvim")
        #expect(package(deprecated: true).replacementID == nil)
    }

    // MARK: - Decode

    @Test("formula deprecation facts decode from the API's flat keys")
    func decodeFormula() throws {
        let json = Data("""
        [{"name": "qt@5", "versions": {"stable": "5.15"}, "deprecated": true, "disabled": false,
          "deprecation_date": "2026-05-19", "deprecation_reason": "unsupported",
          "disable_date": "2027-05-19", "disable_reason": null,
          "deprecation_replacement_formula": "qt", "deprecation_replacement_cask": null}]
        """.utf8)
        let decoded = try #require(try CatalogStore.decodeFormulae(json).first)
        #expect(decoded.deprecationDate == "2026-05-19")
        #expect(decoded.deprecationReason == "unsupported")
        #expect(decoded.disableDate == "2027-05-19")
        #expect(decoded.replacementFormula == "qt")
    }

    @Test("a disabled cask takes the disable replacement, falling back across stanzas")
    func decodeCaskReplacement() throws {
        let json = Data("""
        [{"token": "dead", "deprecated": true, "disabled": true,
          "deprecation_replacement_cask": "old-successor",
          "disable_replacement_cask": "successor"},
         {"token": "dying", "deprecated": true, "disabled": true,
          "deprecation_replacement_cask": "only-named-once"}]
        """.utf8)
        let decoded = try CatalogStore.decodeCasks(json)
        #expect(decoded[0].replacementCask == "successor")
        #expect(decoded[1].replacementCask == "only-named-once")
    }

    @Test("a healthy package sheds leftover deprecation keys, and odd shapes decode as nil")
    func decodeLeniency() throws {
        let json = Data("""
        [{"name": "fine", "deprecated": false, "disabled": false,
          "deprecation_date": "2020-01-01", "deprecation_reason": "unmaintained"},
         {"name": "odd", "deprecated": true, "disabled": false,
          "deprecation_date": 20260519, "deprecation_reason": ["not", "a", "string"]}]
        """.utf8)
        let decoded = try CatalogStore.decodeFormulae(json)
        #expect(decoded[0].deprecationDate == nil)
        #expect(decoded[0].deprecationExplanation == nil)
        #expect(decoded[1].deprecated)
        #expect(decoded[1].deprecationDate == nil)
        #expect(decoded[1].deprecationReason == nil)
    }

    // MARK: - Row phrase

    @Test("the report row's one-liner: verb, slug phrase, disabled wins, prose passes through")
    func attentionPhrase() {
        #expect(package().attentionPhrase == nil)
        #expect(package(deprecated: true, deprecationReason: "unmaintained").attentionPhrase
            == "Deprecated — is not maintained upstream")
        #expect(package(deprecated: true).attentionPhrase == "Deprecated")
        #expect(package(disabled: true).attentionPhrase == "Disabled")
        // Disabled outranks deprecated, and its own reason wins over the deprecation one.
        #expect(package(deprecated: true, disabled: true,
                        deprecationReason: "unmaintained", disableReason: "does_not_build").attentionPhrase
            == "Disabled — does not build")
        // Free maintainer prose passes through the same frame.
        #expect(package(deprecated: true, deprecationReason: "uses a bespoke build").attentionPhrase
            == "Deprecated — uses a bespoke build")
        // Casks use their own table.
        #expect(package(kind: .cask, deprecated: true, deprecationReason: "discontinued").attentionPhrase
            == "Deprecated — is discontinued upstream")
    }
}


/// The card-title disambiguator: charles@4's display name hides its version, charles's
/// doesn't differ — the suffix is what keeps their cards distinct at a glance.
struct TitleVersionSuffixTests {
    private func package(name: String, displayName: String?) -> Package {
        Package(kind: .cask, name: name, displayName: displayName, desc: nil,
                homepage: nil, version: "1", deprecated: false, disabled: false)
    }

    @Test func versionedCaskExposesItsSuffix() {
        #expect(package(name: "charles@4", displayName: "Charles").titleVersionSuffix == "@4")
    }

    @Test func unversionedCaskHasNone() {
        #expect(package(name: "charles", displayName: "Charles").titleVersionSuffix == nil)
    }

    @Test func rawNameTitlesAlreadyShowTheVersion() {
        // Formulae and display-name-less casks render the token itself — no suffix to add.
        #expect(package(name: "python@3.14", displayName: nil).titleVersionSuffix == nil)
    }
}
