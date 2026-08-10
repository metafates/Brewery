//
//  FuzzySearch.swift
//  Brewery
//

import Foundation

/// One ranked result. Carries *why* it matched so a card can caption a command hit — a package
/// surfaced only because it provides `convert` otherwise looks like a false positive.
nonisolated struct SearchHit: Identifiable, Hashable {
    let package: Package
    /// Non-nil only when the command index produced the winning score.
    let matchedCommand: String?

    var id: Package.ID { package.id }
}

/// Pure fuzzy scorer over the catalog. Everything works on lowercased UTF-8 bytes: the query is
/// normalized once per search and candidates are folded into a single reused buffer, so ranking the
/// full ~16k package catalog on every keystroke stays allocation-free.
nonisolated enum FuzzySearch {

    /// Ranked results handed to the grid are capped; an empty query is uncapped.
    static let resultLimit = 200

    /// A query exactly naming a provided command. Below a prefix match on purpose: someone typing
    /// `convert` probably wants imagemagick, but a formula literally named that still wins.
    static let commandExactScore = 850

    /// Command-prefix matching needs at least two characters — one letter prefixes thousands of
    /// executables and would drown the name matches.
    static let commandPrefixMinimum = 2

    // MARK: - Scoring

    /// Score of `query` against a single candidate string. `nil` means no match.
    static func score(query: String, candidate: String) -> Int? {
        var q: [UInt8] = []
        var c: [UInt8] = []
        fold(&q, query)
        fold(&c, candidate)
        return score(query: q, candidate: c)
    }

    /// Score of `query` against a package: the best of `name` and `displayName`. Only when both
    /// miss entirely does a `desc` substring match count, at a flat 40.
    static func score(query: String, package: Package) -> Int? {
        var q: [UInt8] = []
        fold(&q, query)
        var buffer: [UInt8] = []
        return score(query: q, package: package, buffer: &buffer)
    }

    /// Filters and orders `packages` by descending score, tie-broken by shorter then alphabetical
    /// name. An empty query bypasses ranking and returns everything, alphabetical and uncapped.
    ///
    /// `commands` maps a provided executable to every package in the *whole* catalog that installs
    /// it, so a command hit only ever counts for a package actually present in `packages` —
    /// Installed and Outdated pass their own subset and must never surface a stranger.
    @concurrent static func rank(query: String, in packages: [Package],
                                 commands: [String: [Package.ID]] = [:]) async -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return packages.sorted(by: isOrderedBefore).map { SearchHit(package: $0, matchedCommand: nil) }
        }

        var q: [UInt8] = []
        fold(&q, trimmed)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64)

        let byCommand = commandScores(query: q, commands: commands)

        var scored: [(package: Package, score: Int, command: String?)] = []
        scored.reserveCapacity(256)
        for package in packages {
            let nameScore = score(query: q, package: package, buffer: &buffer)
            // Strictly beats: a tie means the name matched too, and "Provides x" would mislead.
            if !byCommand.isEmpty, let hit = byCommand[package.id],
               hit.score > (nameScore ?? Int.min) {
                scored.append((package, hit.score, hit.command))
            } else if let nameScore {
                scored.append((package, nameScore, nil))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.package.name.count != rhs.package.name.count {
                return lhs.package.name.count < rhs.package.name.count
            }
            return isOrderedBefore(lhs.package, rhs.package)
        }
        return scored.prefix(resultLimit).map { SearchHit(package: $0.package, matchedCommand: $0.command) }
    }

    /// Best command score per package ID: an exact command is 850, a prefix of one (≥ 2 chars) is
    /// `600 - command length`. One pass over the index keys, folding into a reused buffer.
    private static func commandScores(query q: [UInt8],
                                      commands: [String: [Package.ID]]) -> [Package.ID: (score: Int, command: String)] {
        guard !q.isEmpty, !commands.isEmpty else { return [:] }

        var best: [Package.ID: (score: Int, command: String)] = [:]
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64)

        for (command, ids) in commands {
            fold(&buffer, command)
            let value: Int
            if buffer == q {
                value = commandExactScore
            } else if q.count >= commandPrefixMinimum, buffer.count > q.count,
                      matches(q, in: buffer, at: 0) {
                value = 600 - buffer.count
            } else {
                continue
            }
            for id in ids {
                if let existing = best[id],
                   existing.score > value || (existing.score == value && existing.command <= command) {
                    continue  // ties resolve alphabetically, so the caption never depends on hash order
                }
                best[id] = (value, command)
            }
        }
        return best
    }

    // MARK: - Byte-level implementation

    private static func score(query q: [UInt8], package: Package, buffer: inout [UInt8]) -> Int? {
        guard !q.isEmpty else { return nil }

        fold(&buffer, package.name)
        var best = score(query: q, candidate: buffer)
        if let displayName = package.displayName {
            fold(&buffer, displayName)
            if let value = score(query: q, candidate: buffer) {
                best = best.map { Swift.max($0, value) } ?? value
            }
        }
        if let best { return best }

        if let desc = package.desc {
            fold(&buffer, desc)
            if contains(q, in: buffer) { return 40 }
        }
        return nil
    }

    private static func score(query q: [UInt8], candidate c: [UInt8]) -> Int? {
        guard !q.isEmpty, c.count >= q.count else { return nil }
        // Equal lengths admit no match other than equality — substring and subsequence both
        // degenerate to it.
        if c.count == q.count { return c == q ? 1000 : nil }

        if matches(q, in: c, at: 0) { return 900 - c.count }

        let limit = c.count - q.count
        var substringStart = -1
        var index = 1
        while index <= limit {
            if c[index] == q[0], matches(q, in: c, at: index) {
                if isWordBoundary(c[index - 1]) { return 700 - index }
                if substringStart < 0 { substringStart = index }
            }
            index += 1
        }
        if substringStart >= 0 { return 500 - substringStart }

        // Subsequence: greedy leftmost match, rewarded for every pair of adjacent hits.
        var queryIndex = 0
        var contiguity = 0
        var previous = -2
        var scan = 0
        while scan < c.count, queryIndex < q.count {
            if c[scan] == q[queryIndex] {
                if scan == previous + 1 { contiguity += 1 }
                previous = scan
                queryIndex += 1
            }
            scan += 1
        }
        return queryIndex == q.count ? 100 + contiguity : nil
    }

    private static func matches(_ q: [UInt8], in c: [UInt8], at index: Int) -> Bool {
        var offset = 0
        while offset < q.count {
            if c[index + offset] != q[offset] { return false }
            offset += 1
        }
        return true
    }

    private static func contains(_ q: [UInt8], in c: [UInt8]) -> Bool {
        guard !q.isEmpty, c.count >= q.count else { return false }
        let limit = c.count - q.count
        var index = 0
        while index <= limit {
            if c[index] == q[0], matches(q, in: c, at: index) { return true }
            index += 1
        }
        return false
    }

    private static func isWordBoundary(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "@")
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: " ")
    }

    /// Lowercases `string` into `buffer`, reusing its storage. ASCII — every package name and
    /// nearly every display name — folds byte-wise without touching String; anything else falls
    /// back to full Unicode lowercasing.
    private static func fold(_ buffer: inout [UInt8], _ string: String) {
        buffer.removeAll(keepingCapacity: true)
        var isASCII = true
        for byte in string.utf8 {
            if byte >= 0x80 {
                isASCII = false
                break
            }
            buffer.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
        }
        guard !isASCII else { return }
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: string.lowercased().utf8)
    }

    private static func isOrderedBefore(_ lhs: Package, _ rhs: Package) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}
