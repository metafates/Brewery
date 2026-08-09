//
//  FuzzySearchTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("Fuzzy search")
struct FuzzySearchTests {

    // MARK: - Fixtures

    private static func formula(_ name: String, desc: String? = nil) -> Package {
        Package(kind: .formula,
                name: name,
                displayName: nil,
                desc: desc,
                homepage: nil,
                version: "1.0",
                deprecated: false,
                disabled: false)
    }

    private static func cask(_ token: String, displayName: String?, desc: String? = nil) -> Package {
        Package(kind: .cask,
                name: token,
                displayName: displayName,
                desc: desc,
                homepage: nil,
                version: "1.0",
                deprecated: false,
                disabled: false)
    }

    // MARK: - Scoring rungs

    /// The five name rungs must stay strictly ordered, with the exact values the doc specifies.
    @Test("exact > prefix > word boundary > substring > subsequence")
    func rungOrdering() {
        let exact = FuzzySearch.score(query: "git", candidate: "git")
        let prefix = FuzzySearch.score(query: "git", candidate: "github")
        let boundary = FuzzySearch.score(query: "git", candidate: "lazy-git")
        let substring = FuzzySearch.score(query: "git", candidate: "legit")
        let subsequence = FuzzySearch.score(query: "git", candidate: "gxixt")

        #expect(exact == 1000)
        #expect(prefix == 900 - 6)          // 900 - candidate length
        #expect(boundary == 700 - 5)        // 700 - match position
        #expect(substring == 500 - 2)       // 500 - match position
        #expect(subsequence == 100)         // 100 + contiguity bonus

        let ladder = [exact, prefix, boundary, substring, subsequence].compactMap { $0 }
        #expect(ladder.count == 5)
        #expect(ladder == ladder.sorted(by: >))
    }

    /// Only `-` `_` `@` `.` and space open a word; a letter before the match is a plain substring.
    @Test("word-boundary separators")
    func wordBoundarySeparators() {
        #expect(FuzzySearch.score(query: "git", candidate: "lazy_git") == 700 - 5)
        #expect(FuzzySearch.score(query: "git", candidate: "lazy git") == 700 - 5)
        #expect(FuzzySearch.score(query: "git", candidate: "lazy.git") == 700 - 5)
        #expect(FuzzySearch.score(query: "12", candidate: "python@12") == 700 - 7)
        #expect(FuzzySearch.score(query: "git", candidate: "lazygit") == 500 - 4)
    }

    /// Adjacent matched pairs are what separates two otherwise equal subsequence matches.
    @Test("subsequence contiguity bonus")
    func subsequenceContiguity() {
        #expect(FuzzySearch.score(query: "git", candidate: "gxit") == 101)
        #expect(FuzzySearch.score(query: "git", candidate: "gxixt") == 100)
    }

    @Test("case-insensitive in both directions")
    func caseInsensitivity() {
        #expect(FuzzySearch.score(query: "GIT", candidate: "git") == 1000)
        #expect(FuzzySearch.score(query: "git", candidate: "GIT") == 1000)
        #expect(FuzzySearch.score(query: "GiT", candidate: "GitHub") == FuzzySearch.score(query: "git", candidate: "github"))

        let vscode = Self.cask("visual-studio-code", displayName: "Visual Studio Code")
        #expect(FuzzySearch.score(query: "VISUAL", package: vscode)
                == FuzzySearch.score(query: "visual", package: vscode))
    }

    @Test("no match returns nil")
    func noMatch() {
        #expect(FuzzySearch.score(query: "zq", candidate: "git") == nil)
        #expect(FuzzySearch.score(query: "wget", candidate: "wg") == nil)   // query longer than candidate
        #expect(FuzzySearch.score(query: "abc", candidate: "cba") == nil)   // same length, not equal
        #expect(FuzzySearch.score(query: "", candidate: "git") == nil)
        #expect(FuzzySearch.score(query: "zzq", package: Self.formula("wget", desc: "Internet file retriever")) == nil)
    }

    // MARK: - Package scoring

    @Test("a desc-only match ranks below any name match")
    func descMatchRanksLast() async {
        let descOnly = Self.formula("fd", desc: "Simple, fast alternative to find")
        let weakestNameMatch = Self.formula("f-i-n-d")   // subsequence only: the lowest name rung

        #expect(FuzzySearch.score(query: "find", package: descOnly) == 40)
        #expect(FuzzySearch.score(query: "find", package: weakestNameMatch) == 100)

        let ranked = await FuzzySearch.rank(query: "find", in: [descOnly, weakestNameMatch])
        #expect(ranked.map(\.name) == ["f-i-n-d", "fd"])
    }

    @Test("\"git\" ranks git above gitless and gitui")
    func gitOrdering() async {
        let packages = [
            Self.formula("gitless", desc: "Version control system built on top of Git"),
            Self.formula("lazygit", desc: "Simple terminal UI for git commands"),
            Self.formula("git", desc: "Distributed revision control system"),
            Self.formula("tig", desc: "Text interface for Git repositories"),
            Self.formula("gitui", desc: "Blazing fast terminal client for git"),
        ]

        let ranked = await FuzzySearch.rank(query: "git", in: packages)
        #expect(ranked.map(\.name) == ["git", "gitui", "gitless", "lazygit", "tig"])

        // Case must not change the outcome.
        let upper = await FuzzySearch.rank(query: "GIT", in: packages)
        #expect(upper.map(\.name) == ranked.map(\.name))
    }

    @Test("a cask is found by its display name")
    func caskFoundByDisplayName() async {
        let vscode = Self.cask("visual-studio-code",
                               displayName: "Visual Studio Code",
                               desc: "Open-source code editor")
        let other = Self.cask("visual-paradigm", displayName: "Visual Paradigm")
        let noise = Self.formula("vim", desc: "Vi 'workalike' with many additional features")

        // The token has no space, so only the display name can match.
        #expect(FuzzySearch.score(query: "visual studio", candidate: "visual-studio-code") == nil)
        #expect(FuzzySearch.score(query: "visual studio", package: vscode) == 900 - 18)

        let ranked = await FuzzySearch.rank(query: "visual studio", in: [noise, other, vscode])
        #expect(ranked.map(\.name) == ["visual-studio-code"])
    }

    // MARK: - Ranking rules

    @Test("an empty query bypasses ranking: alphabetical and uncapped")
    func emptyQueryBypassesRanking() async {
        let packages = [Self.formula("wget"), Self.formula("aria2"), Self.cask("iterm2", displayName: "iTerm2")]

        let ranked = await FuzzySearch.rank(query: "   ", in: packages)
        #expect(ranked.map(\.name) == ["aria2", "iterm2", "wget"])
        #expect(ranked.count == packages.count)
    }

    @Test("results are capped, ties broken by shorter then alphabetical name")
    func resultCapAndTieBreak() async {
        let many = (0..<250).map { Self.formula("pkg\($0)-tool") }
        let ranked = await FuzzySearch.rank(query: "pkg", in: many)
        #expect(ranked.count == FuzzySearch.resultLimit)

        // Same score (prefix, equal length) → shorter name first, then alphabetical.
        let tied = [Self.formula("ab-two"), Self.formula("ab-one"), Self.formula("ab")]
        let order = await FuzzySearch.rank(query: "ab", in: tied)
        #expect(order.map(\.name) == ["ab", "ab-one", "ab-two"])
    }
}
