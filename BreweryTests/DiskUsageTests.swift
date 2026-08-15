//
//  DiskUsageTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("Disk usage measurement")
struct DiskUsageTests {

    /// Files sum by logical size, nested directories included, symlinks never followed —
    /// a keg's bin links point outside the keg and would double-count or escape.
    @Test func sumsFilesAndSkipsSymlinks() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "DiskUsageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "keg", directoryHint: .isDirectory)
        let sub = root.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Data("abc".utf8).write(to: root.appending(path: "a", directoryHint: .notDirectory))
        try Data("hello".utf8).write(to: sub.appending(path: "b", directoryHint: .notDirectory))

        // A large file outside the root, reachable only through a symlink inside it.
        let outside = base.appending(path: "outside", directoryHint: .notDirectory)
        try Data(repeating: 0, count: 4096).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link", directoryHint: .notDirectory),
            withDestinationURL: outside)

        #expect(await DiskUsage.bytes(at: [root]) == 8)

        // A file root (an installed font) counts directly; roots combine.
        #expect(await DiskUsage.bytes(at: [root, outside]) == 8 + 4096)

        // Nothing on disk is nil — a read failure, never "Zero bytes".
        let missing = base.appending(path: "gone", directoryHint: .isDirectory)
        #expect(await DiskUsage.bytes(at: [missing]) == nil)
        #expect(await DiskUsage.bytes(at: [missing, root]) == 8)
    }
}
