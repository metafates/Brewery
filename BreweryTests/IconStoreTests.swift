//
//  IconStoreTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("Icon cache eviction")
struct IconEvictionTests {
    /// Fixed reference point so the fixtures never depend on when the suite runs.
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func file(_ name: String, _ size: Int, ageInDays: Double)
        -> (name: String, size: Int, mtime: Date) {
        (name, size, base.addingTimeInterval(-ageInDays * 24 * 60 * 60))
    }

    @Test("nothing to do while the directory fits")
    func underCap() {
        let files = [Self.file("a", 400, ageInDays: 9),
                     Self.file("b", 400, ageInDays: 1)]
        #expect(IconStore.evictions(files, cap: 1000).isEmpty)
        // Exactly at the cap is still within it — eviction needs an *excess*.
        #expect(IconStore.evictions(files, cap: 800).isEmpty)
    }

    @Test("oldest access goes first")
    func oldestFirst() {
        let files = [Self.file("fresh", 500, ageInDays: 1),
                     Self.file("ancient", 500, ageInDays: 30),
                     Self.file("middling", 500, ageInDays: 7)]
        #expect(IconStore.evictions(files, cap: 1000) == ["ancient"])
    }

    @Test("stops as soon as the total fits")
    func stopsAtCap() {
        let files = [Self.file("a", 300, ageInDays: 40),
                     Self.file("b", 300, ageInDays: 30),
                     Self.file("c", 300, ageInDays: 20),
                     Self.file("d", 300, ageInDays: 10)]
        // 1200 bytes, cap 700: dropping the two oldest leaves 600 — the third survives.
        #expect(IconStore.evictions(files, cap: 700) == ["a", "b"])
    }

    @Test("an empty directory evicts nothing")
    func empty() {
        #expect(IconStore.evictions([], cap: 0).isEmpty)
    }

    @Test("a cap smaller than any single file empties the directory")
    func everythingGoes() {
        let files = [Self.file("a", 100, ageInDays: 2), Self.file("b", 100, ageInDays: 1)]
        #expect(IconStore.evictions(files, cap: 10) == ["a", "b"])
    }
}

@Suite("Negative marker freshness")
struct IconMarkerTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    @Test("a marker written today suppresses the fetch")
    func fresh() {
        #expect(IconStore.isMarkerFresh(birthtime: Self.now.addingTimeInterval(-3600),
                                        now: Self.now,
                                        ttl: Self.week))
        #expect(IconStore.isMarkerFresh(birthtime: Self.now, now: Self.now, ttl: Self.week))
    }

    @Test("past the TTL the host is asked again")
    func expired() {
        #expect(IconStore.isMarkerFresh(birthtime: Self.now.addingTimeInterval(-Self.week - 1),
                                        now: Self.now,
                                        ttl: Self.week) == false)
    }

    /// Only a clock change produces this, and treating it as fresh would pin the entry forever.
    @Test("a birthtime in the future counts as expired")
    func future() {
        #expect(IconStore.isMarkerFresh(birthtime: Self.now.addingTimeInterval(60),
                                        now: Self.now,
                                        ttl: Self.week) == false)
    }
}

@Suite("Tap avatar sources")
struct AvatarSourceTests {
    @Test("owner comes from the remote; built-ins map to Homebrew; anything else is nothing")
    func avatarSource() throws {
        let charm = try #require(IconStore.avatarSource(
            tapName: "charmbracelet/tap", remote: "https://github.com/charmbracelet/homebrew-tap"))
        #expect(charm.url.absoluteString == "https://github.com/charmbracelet.png?size=128")

        // A custom remote wins over the name — the name would have said "someone".
        let custom = try #require(IconStore.avatarSource(
            tapName: "someone/tap", remote: "https://github.com/other-org/homebrew-tap"))
        #expect(custom.url.absoluteString.contains("/other-org.png"))

        // Built-in taps have no clone and no remote; they are Homebrew's own.
        let core = try #require(IconStore.avatarSource(tapName: "homebrew/core", remote: nil))
        #expect(core.url.absoluteString.contains("/homebrew.png"))

        #expect(IconStore.avatarSource(tapName: "x/y", remote: "https://gitlab.com/x/homebrew-y") == nil)
        #expect(IconStore.avatarSource(tapName: "x/y", remote: nil) == nil)
    }
}

@Suite("Package avatar sources")
struct PackageAvatarSourceTests {
    @Test("a dedicated github account (owner == repo) yields its avatar; anything else nothing")
    func avatarFromHomepage() throws {
        let dedicated = try #require(IconStore.avatarSource(
            homepage: URL(string: "https://github.com/XCTestHTMLReport/XCTestHTMLReport")))
        #expect(dedicated.url.absoluteString == "https://github.com/XCTestHTMLReport.png?size=128")
        // Same key namespace as tap avatars — the tile is shared.
        #expect(dedicated.key == IconStore.fileName(for: "avatar_XCTestHTMLReport"))

        // GitHub is case-insensitive; the comparison is too. A .git suffix folds away.
        #expect(IconStore.avatarSource(
            homepage: URL(string: "https://www.github.com/Exiftool/exiftool")) != nil)
        #expect(IconStore.avatarSource(
            homepage: URL(string: "https://github.com/tmux/tmux.git")) != nil)

        // An owner hosting many repos keeps the kind glyph — their avatar isn't this package.
        #expect(IconStore.avatarSource(homepage: URL(string: "https://github.com/sharkdp/bat")) == nil)
        #expect(IconStore.avatarSource(homepage: URL(string: "https://github.com/sponsors")) == nil)
        #expect(IconStore.avatarSource(homepage: URL(string: "https://gitlab.com/x/x")) == nil)
        #expect(IconStore.avatarSource(homepage: URL(string: "https://example.com/x/x")) == nil)
        #expect(IconStore.avatarSource(homepage: nil) == nil)
    }
}

@Suite("Host file names")
struct IconFileNameTests {
    @Test("a plain host is its own file name")
    func plainHost() {
        #expect(IconStore.fileName(for: "code.visualstudio.com") == "code.visualstudio.com")
        #expect(IconStore.fileName(for: "GNU.org") == "gnu.org")
    }

    @Test("nothing can escape the icons directory")
    func traversal() {
        #expect(IconStore.fileName(for: "../../etc/passwd").contains("/") == false)
        #expect(IconStore.fileName(for: "..").isEmpty)
        #expect(IconStore.fileName(for: ".").isEmpty)
        #expect(IconStore.fileName(for: "").isEmpty)
    }
}
