//
//  StateSnapshotTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

/// The launch snapshot must return exactly what was published, and anything it cannot
/// vouch for (wrong version, garbage, absent file) must read as "no snapshot".
@Suite("State snapshot")
struct StateSnapshotTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "state-\(UUID().uuidString).json", directoryHint: .notDirectory)
    }

    @Test("roundtrips all three overlays, receipt fields included")
    func roundtrip() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = StateSnapshot(
            installed: [
                "formula:wget": InstalledInfo(versions: ["1.25.0"], onRequest: true,
                                              dependencies: ["libidn2"], tap: "user/repo",
                                              builtFromSource: true,
                                              installedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                "cask:iterm2": InstalledInfo(versions: ["3.5.11"], apps: ["iTerm.app"], hasZap: true),
            ],
            outdated: ["formula:wget": OutdatedInfo(installed: ["1.24.0"], current: "1.25.0", pinned: true)],
            serviceStatuses: ["redis": ServiceStatus(health: .started, exitCode: nil),
                              "postgresql@17": ServiceStatus(health: .error, exitCode: 1)],
            pinned: ["formula:wget", "cask:iterm2"])
        await snapshot.save(to: url)

        let loaded = StateSnapshot.load(from: url)
        #expect(loaded?.installed == snapshot.installed)
        #expect(loaded?.outdated == snapshot.outdated)
        #expect(loaded?.serviceStatuses == snapshot.serviceStatuses)
        #expect(loaded?.pinned == snapshot.pinned)
    }

    @Test("a snapshot written before the pinned key still loads — no bump for optional additions")
    func missingPinnedKey() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        {"version": \(StateSnapshot.currentVersion), "installed": {}, "outdated": {},
         "serviceStatuses": {}}
        """.utf8).write(to: url)

        let loaded = StateSnapshot.load(from: url)
        #expect(loaded != nil)
        #expect(loaded?.pinned == nil)
    }

    @Test("a version mismatch reads as no snapshot")
    func versionMismatch() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var snapshot = StateSnapshot(installed: [:], outdated: [:], serviceStatuses: [:])
        snapshot.version = StateSnapshot.currentVersion + 1
        await snapshot.save(to: url)

        #expect(StateSnapshot.load(from: url) == nil)
    }

    @Test("garbage and absence read as no snapshot")
    func unreadable() throws {
        let url = temporaryURL()
        #expect(StateSnapshot.load(from: url) == nil)

        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StateSnapshot.load(from: url) == nil)
    }
}
