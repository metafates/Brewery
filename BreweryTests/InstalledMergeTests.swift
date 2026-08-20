//
//  InstalledMergeTests.swift
//  BreweryTests
//

import Testing
@testable import Brewery

/// The per-kind degrade of the installed probe (the harlequin bug): a crashing cask list
/// must not freeze formula state, and vice versa; only both failing keeps everything.
struct InstalledMergeTests {
    private let previous: [Package.ID: InstalledInfo] = [
        "formula:harlequin": InstalledInfo(versions: ["2.9.0"]),
        "formula:wget": InstalledInfo(versions: ["1.25.0"]),
        "cask:font-inter": InstalledInfo(versions: ["4.0"]),
    ]

    @Test func freshSidesReplaceWholesale() {
        let merged = AppModel.mergeInstalled(
            formulae: ["formula:wget": InstalledInfo(versions: ["1.25.0"])],
            casks: [:],
            previous: previous)
        #expect(Set(merged!.keys) == ["formula:wget"])
    }

    @Test func failedCaskSideKeepsItsStaleEntriesOnly() {
        // The live bug's shape: formulae fresh (harlequin uninstalled), cask list crashed.
        let merged = AppModel.mergeInstalled(
            formulae: ["formula:wget": InstalledInfo(versions: ["1.25.0"])],
            casks: nil,
            previous: previous)
        #expect(Set(merged!.keys) == ["formula:wget", "cask:font-inter"])
    }

    @Test func failedFormulaSideKeepsItsStaleEntriesOnly() {
        let merged = AppModel.mergeInstalled(
            formulae: nil,
            casks: [:],
            previous: previous)
        #expect(Set(merged!.keys) == ["formula:harlequin", "formula:wget"])
    }

    @Test func bothFailedReadsAsOffline() {
        #expect(AppModel.mergeInstalled(formulae: nil, casks: nil, previous: previous) == nil)
    }
}
