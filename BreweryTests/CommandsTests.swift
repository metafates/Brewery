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
