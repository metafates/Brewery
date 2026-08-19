//
//  MetadataFreshnessTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// The staleness gate's two pure pieces: which cache directory brew will use for the
/// processes we spawn, and which file's mtime counts as "metadata last known good".
struct MetadataFreshnessTests {

    @Test func cacheDirectoryPrefersInheritedOverride() {
        let home = URL(filePath: "/Users/someone")
        #expect(BrewClient.apiDirectory(environment: ["HOMEBREW_CACHE": "/custom/cache"], home: home)
            == URL(filePath: "/custom/cache/api/internal"))
        #expect(BrewClient.apiDirectory(environment: [:], home: home)
            == URL(filePath: "/Users/someone/Library/Caches/Homebrew/api/internal"))
    }

    @Test func newestPayloadWinsAndSiblingsAreIgnored() throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = Date(timeIntervalSinceNow: -3600)
        let newest = Date(timeIntervalSinceNow: -600)
        let evenNewerButWrongFile = Date(timeIntervalSinceNow: -60)

        try stamp("packages.arm64_tahoe.jws.json", in: directory, mtime: older)
        try stamp("packages.x86_64_linux.jws.json", in: directory, mtime: newest)
        // brew rewrites these on parse, not on refresh — they must not count.
        try stamp("packages.arm64_tahoe.jws.json.payload", in: directory, mtime: evenNewerButWrongFile)
        try stamp("packages.arm64_tahoe.jws.json.payload.index", in: directory, mtime: evenNewerButWrongFile)
        try stamp("executables.txt", in: directory, mtime: evenNewerButWrongFile)

        let result = try #require(BrewClient.newestMetadataDate(in: directory))
        #expect(abs(result.timeIntervalSince(newest)) < 1)
    }

    @Test func missingOrPayloadFreeDirectoryIsMaximallyStale() throws {
        #expect(BrewClient.newestMetadataDate(in: URL(filePath: "/nonexistent/api/internal")) == nil)

        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try stamp("executables.txt", in: directory, mtime: .now)
        #expect(BrewClient.newestMetadataDate(in: directory) == nil)
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "metadata-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func stamp(_ name: String, in directory: URL, mtime: Date) throws {
        let url = directory.appending(path: name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
}
