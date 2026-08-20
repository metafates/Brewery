//
//  PinStoreTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// The ledger scan against real directories: brew's per-kind dangling semantics, absence as
/// zero pins, kind from the directory, and stray files ignored.
@Suite("Pin ledger scan")
struct PinStoreTests {
    /// A throwaway prefix with optional pin entries. `target: nil` makes a dangling link.
    private func makePrefix() throws -> URL {
        let prefix = FileManager.default.temporaryDirectory
            .appending(path: "pins-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        return prefix
    }

    private func addPin(_ name: String, directory: String, prefix: URL,
                        dangling: Bool = false) throws {
        let root = prefix.appending(path: "var/homebrew/\(directory)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = prefix.appending(path: "Cellar/\(name)/1.0", directoryHint: .isDirectory)
        if !dangling {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: name, directoryHint: .notDirectory),
            withDestinationURL: target)
    }

    @Test("both kinds scan; the kind comes from the directory, even for one shared name")
    func kinds() async throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try addPin("wget", directory: "pinned", prefix: prefix)
        try addPin("iterm2", directory: "pinned_casks", prefix: prefix)
        try addPin("shared", directory: "pinned", prefix: prefix)
        try addPin("shared", directory: "pinned_casks", prefix: prefix)

        let pins = await PinStore.scan(prefix: prefix)
        #expect(pins == ["formula:wget", "cask:iterm2", "formula:shared", "cask:shared"])
    }

    @Test("dangling pins follow brew's predicates: formulae count, casks do not")
    func dangling() async throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try addPin("ghost", directory: "pinned", prefix: prefix, dangling: true)
        try addPin("phantom", directory: "pinned_casks", prefix: prefix, dangling: true)

        let pins = await PinStore.scan(prefix: prefix)
        #expect(pins == ["formula:ghost"])
    }

    @Test("missing directories and a nil prefix mean zero pins, not an error")
    func absence() async throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        #expect(await PinStore.scan(prefix: prefix).isEmpty)
        #expect(await PinStore.scan(prefix: nil).isEmpty)
    }

    @Test("a stray regular file is not a pin")
    func strayFile() async throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let root = prefix.appending(path: "var/homebrew/pinned", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: ".DS_Store", directoryHint: .notDirectory))

        #expect(await PinStore.scan(prefix: prefix).isEmpty)
    }
}
