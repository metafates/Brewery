//
//  FontPreviewTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("Font preview face resolution")
struct FontPreviewTests {

    /// The artifact name in the API is a source-relative path (`ttf/Hack-Regular.ttf`);
    /// the installed file is its basename under fontdir. A fixture directory stands in
    /// for `~/Library/Fonts` so the test never depends on what this machine has installed.
    @Test func fontURLResolvesBasename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "FontPreviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let installed = dir.appending(path: "Hack-Regular.ttf", directoryHint: .notDirectory)
        try Data().write(to: installed)

        #expect(FontPreview.fontURL(named: "ttf/Hack-Regular.ttf", in: dir) == installed)
        #expect(FontPreview.fontURL(named: "Hack-Regular.ttf", in: dir) == installed)
        #expect(FontPreview.fontURL(named: "ttf/Hack-Italic.ttf", in: dir) == nil)
    }

    /// Helvetica ships with every macOS as a `.ttc` — one file, several faces. This pins
    /// the collection handling and that names come out non-empty.
    @Test func facesFromSystemCollection() {
        let faces = FontPreview.faces(at: URL(filePath: "/System/Library/Fonts/Helvetica.ttc"))
        #expect(faces.count > 1)
        #expect(faces.allSatisfy { !$0.postScriptName.isEmpty && !$0.family.isEmpty })
        #expect(faces.contains { $0.family == "Helvetica" })
    }

    @Test func unparseableFileYieldsNoFaces() {
        #expect(FontPreview.faces(at: URL(filePath: "/nonexistent/nope.ttf")).isEmpty)
    }

    /// Ordering is display order: weights ascend, italic follows its upright, duplicate
    /// PostScript names (the same file listed twice) collapse.
    @Test func orderingAndDedup() {
        let regular = FontPreview.Face(postScriptName: "X-Regular", family: "X", style: "Regular", weight: 0, italic: false)
        let italic = FontPreview.Face(postScriptName: "X-Italic", family: "X", style: "Italic", weight: 0, italic: true)
        let bold = FontPreview.Face(postScriptName: "X-Bold", family: "X", style: "Bold", weight: 0.4, italic: false)

        #expect(FontPreview.order([bold, italic, regular, regular]) == [regular, italic, bold])
    }
}
