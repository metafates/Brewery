//
//  StorageTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

@Suite("Storage report (v18)")
struct StorageTests {

    private let prefix = URL(filePath: "/opt/homebrew")

    @Test("old kegs are every version but the current, namespaced against the whole-rack cache")
    func oldKegRoots() {
        let roots = AppModel.oldKegRoots(prefix: prefix, name: "python@3.12",
                                         versions: ["3.12.1", "3.12.4", "3.12.14"])
        #expect(roots.count == 2)
        #expect(roots[0].key == "oldkeg:formula:python@3.12|3.12.1")
        #expect(roots[0].root.path == "/opt/homebrew/Cellar/python@3.12/3.12.1")
        #expect(roots[1].key == "oldkeg:formula:python@3.12|3.12.4")
        #expect(roots[1].root.path == "/opt/homebrew/Cellar/python@3.12/3.12.4")
        // The namespace is the point: the pane caches whole-rack bytes under the bare
        // "formula:name|version" key, and one key must never mean two measurements.
        #expect(roots.allSatisfy { $0.key.hasPrefix("oldkeg:") })
    }

    @Test("a single-version formula has no old kegs; empty versions stay empty")
    func oldKegRootsEdges() {
        #expect(AppModel.oldKegRoots(prefix: prefix, name: "wget", versions: ["1.25.0"]).isEmpty)
        #expect(AppModel.oldKegRoots(prefix: prefix, name: "wget", versions: []).isEmpty)
    }

    @Test("cache and logs directories: env override wins, macOS defaults otherwise")
    func directoryResolution() {
        let home = URL(filePath: "/Users/test")
        #expect(BrewClient.cacheDirectory(environment: ["HOMEBREW_CACHE": "/custom/cache"], home: home)
            .path == "/custom/cache")
        #expect(BrewClient.cacheDirectory(environment: [:], home: home)
            .path == "/Users/test/Library/Caches/Homebrew")
        #expect(BrewClient.logsDirectory(environment: ["HOMEBREW_LOGS": "/custom/logs"], home: home)
            .path == "/custom/logs")
        #expect(BrewClient.logsDirectory(environment: [:], home: home)
            .path == "/Users/test/Library/Logs/Homebrew")
    }
}
