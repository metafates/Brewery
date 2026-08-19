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

    private static func formula(_ name: String, desc: String? = nil, commands: [String] = []) -> Package {
        Package(kind: .formula,
                name: name,
                displayName: nil,
                desc: desc,
                homepage: nil,
                version: "1.0",
                deprecated: false,
                disabled: false,
                commands: commands)
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
        #expect(ranked.map(\.package.name) == ["f-i-n-d", "fd"])
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
        #expect(ranked.map(\.package.name) == ["git", "gitui", "gitless", "lazygit", "tig"])

        // Case must not change the outcome.
        let upper = await FuzzySearch.rank(query: "GIT", in: packages)
        #expect(upper.map(\.package.name) == ranked.map(\.package.name))
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
        #expect(ranked.map(\.package.name) == ["visual-studio-code"])
    }

    // MARK: - Ranking rules

    @Test("an empty query bypasses ranking: alphabetical and uncapped")
    func emptyQueryBypassesRanking() async {
        let packages = [Self.formula("wget"), Self.formula("aria2"), Self.cask("iterm2", displayName: "iTerm2")]

        let ranked = await FuzzySearch.rank(query: "   ", in: packages)
        #expect(ranked.map(\.package.name) == ["aria2", "iterm2", "wget"])
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
        #expect(order.map(\.package.name) == ["ab", "ab-one", "ab-two"])
    }

    // MARK: - Command index

    /// The index the app actually feeds the ranker, so these tests exercise the real inversion too.
    private static func index(_ packages: [Package]) async -> [String: [Package.ID]] {
        await AppModel.buildCommandIndex(packages)
    }

    @Test("the command index lists every provider of a command")
    func commandIndexInversion() async {
        let packages = [
            Self.formula("openjdk", commands: ["java", "javac"]),
            Self.formula("openjdk@17", commands: ["java"]),
            Self.cask("temurin", displayName: "Eclipse Temurin"),
        ]

        let index = await Self.index(packages)
        #expect(index["java"]?.sorted() == ["formula:openjdk", "formula:openjdk@17"])
        #expect(index["javac"] == ["formula:openjdk"])
        // Casks carry no commands, so the index can only ever point at a formula.
        #expect(index.values.allSatisfy { $0.allSatisfy { $0.hasPrefix("formula:") } })
    }

    @Test("an exact command match ranks below a name-exact package and above a substring name match")
    func commandExactRanking() async {
        let packages = [
            Self.formula("convert", desc: "Unit conversion tool"),
            Self.formula("imagemagick", desc: "Tools and libraries to manipulate images",
                         commands: ["convert", "identify", "mogrify"]),
            Self.formula("reconvert"),
        ]

        let ranked = await FuzzySearch.rank(query: "convert",
                                            in: packages,
                                            commands: await Self.index(packages))

        #expect(ranked.map(\.package.name) == ["convert", "imagemagick", "reconvert"])
        // Only the package the index surfaced explains itself; a name match must stay uncaptioned.
        #expect(ranked.map(\.matchedCommand) == [nil, "convert", nil])
    }

    @Test("command-prefix matching needs at least two characters")
    func commandPrefixMinimum() async {
        // netpbm's name shares no letter with "j", so only the index can ever surface it here.
        let packages = [Self.formula("netpbm", commands: ["jpegtopnm", "pnmtojpeg"])]
        let index = await Self.index(packages)

        let two = await FuzzySearch.rank(query: "jp", in: packages, commands: index)
        #expect(two.map(\.package.name) == ["netpbm"])
        #expect(two.first?.matchedCommand == "jpegtopnm")   // 600 - 9, the shorter prefix hit wins

        let one = await FuzzySearch.rank(query: "j", in: packages, commands: index)
        #expect(one.isEmpty)
    }

    @Test("a command hit never surfaces a package outside the passed subset")
    func commandHitRespectsSubset() async {
        let imagemagick = Self.formula("imagemagick", desc: "Tools and libraries to manipulate images",
                                       commands: ["convert", "identify"])
        let imageoptim = Self.cask("imageoptim", displayName: "ImageOptim", desc: "Image compressor")
        let index = await Self.index([imagemagick, imageoptim])

        // The index maps commands over the whole catalog…
        let whole = await FuzzySearch.rank(query: "convert", in: [imagemagick, imageoptim], commands: index)
        #expect(whole.map(\.package.name) == ["imagemagick"])

        // …but Installed and Outdated pass a subset, which must never gain a stranger.
        let subset = await FuzzySearch.rank(query: "convert", in: [imageoptim], commands: index)
        #expect(subset.isEmpty)
    }

    // MARK: - Tap-qualified candidate

    private static func tapFormula(_ name: String, tap: String) -> Package {
        Package(kind: .formula, name: name, displayName: nil, desc: nil, homepage: nil,
                version: "1.0", deprecated: false, disabled: false, tap: tap)
    }

    @Test("searching a tap owner surfaces that tap's packages")
    func tapOwnerQuery() async {
        let gum = Self.tapFormula("gum", tap: "charmbracelet/tap")
        let wget = Self.formula("wget", desc: "Internet file retriever")

        let hits = await FuzzySearch.rank(query: "charmbracelet", in: [wget, gum])
        #expect(hits.map(\.package.name) == ["gum"])
    }

    @Test("a qualified hit never outranks an exact short-name match elsewhere")
    func qualifiedNeverBeatsExact() async {
        // Tap "gum/tools" ships "row" — its qualified string "gum/tools/row" prefix-matches
        // a "gum" query. The package literally named gum must still win.
        let decoy = Self.tapFormula("row", tap: "gum/tools")
        let exact = Self.formula("gum")

        let hits = await FuzzySearch.rank(query: "gum", in: [decoy, exact])
        #expect(hits.first?.package.name == "gum")
    }

    @Test("qualified scoring never fires for core packages")
    func qualifiedNeedsTap() async {
        // If core packages were scored against a synthetic qualified string, "homebrew" would
        // suddenly match everything.
        let wget = Self.formula("wget")
        let hits = await FuzzySearch.rank(query: "homebrew", in: [wget])
        #expect(hits.isEmpty)
    }
}
