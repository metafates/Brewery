//
//  CommandsTests.swift
//  BreweryTests
//
//  v13 — the Commands section's order. The API's ASCII order front-loaded the capitals
//  block (llvm led with FileCheck · UnicodeNameMappingGenerator); display order is
//  case-insensitive with the raw name as a deterministic tiebreak.
//

import Testing
@testable import Brewery

struct CommandsTests {
    private func package(commands: [String]) -> Package {
        Package(kind: .formula, name: "llvm", displayName: nil, desc: nil, homepage: nil,
                version: "22.0.0", deprecated: false, disabled: false, commands: commands)
    }

    @Test func displayOrderInterleavesCapitals() {
        let package = package(commands: ["UnicodeNameMappingGenerator", "amdgpu-arch",
                                         "FileCheck", "clang", "lldb"])
        #expect(package.displayCommands == ["amdgpu-arch", "clang", "FileCheck",
                                            "lldb", "UnicodeNameMappingGenerator"])
    }

    @Test func displayOrderBreaksCaseTiesDeterministically() {
        let package = package(commands: ["Clang", "clang"])
        #expect(package.displayCommands == ["Clang", "clang"])
    }
}

/// v14 — the popularity comparator, hoisted to Package for the tap page (comparators are pure
/// statics with tests).
struct PopularityOrderTests {
    private func package(_ name: String, installs: Int?) -> Package {
        Package(kind: .formula, name: name, displayName: nil, desc: nil, homepage: nil,
                version: "1", deprecated: false, disabled: false, installs90d: installs)
    }

    @Test func mostInstalledComesFirstAndTiesFallToName() {
        let sorted = [package("b", installs: 5), package("a", installs: 5),
                      package("niche", installs: nil), package("hot", installs: 100)]
            .sorted(by: Package.popularityOrder)
        #expect(sorted.map(\.name) == ["hot", "a", "b", "niche"])
    }
}
