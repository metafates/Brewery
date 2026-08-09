//
//  FuzzySearch.swift
//  Brewery
//

import Foundation

/// Pure fuzzy scorer over the catalog. Everything works on lowercased UTF-8 bytes: the query is
/// normalized once per search and candidates are folded into a single reused buffer, so ranking the
/// full ~16k package catalog on every keystroke stays allocation-free.
nonisolated enum FuzzySearch {

    /// Ranked results handed to the grid are capped; an empty query is uncapped.
    static let resultLimit = 200

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
    @concurrent static func rank(query: String, in packages: [Package]) async -> [Package] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return packages.sorted(by: isOrderedBefore) }

        var q: [UInt8] = []
        fold(&q, trimmed)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64)

        var scored: [(package: Package, score: Int)] = []
        scored.reserveCapacity(256)
        for package in packages {
            if let value = score(query: q, package: package, buffer: &buffer) {
                scored.append((package, value))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.package.name.count != rhs.package.name.count {
                return lhs.package.name.count < rhs.package.name.count
            }
            return isOrderedBefore(lhs.package, rhs.package)
        }
        return scored.prefix(resultLimit).map(\.package)
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
