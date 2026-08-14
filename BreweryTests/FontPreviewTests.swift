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

    private static func face(_ postScript: String, family: String, style: String,
                             weight: Double, italic: Bool = false) -> FontPreview.Face {
        FontPreview.Face(postScriptName: postScript, family: family, style: style,
                         weight: weight, italic: italic)
    }

    /// A single family reads as a type specimen: Regular, Italic, Bold, Bold Italic —
    /// weights by distance from regular, upright before italic, duplicates collapsed.
    @Test func singleFamilyOrder() {
        let regular = Self.face("X-Regular", family: "X", style: "Regular", weight: 0)
        let italic = Self.face("X-Italic", family: "X", style: "Italic", weight: 0, italic: true)
        let bold = Self.face("X-Bold", family: "X", style: "Bold", weight: 0.4)
        let boldItalic = Self.face("X-BoldItalic", family: "X", style: "Bold Italic", weight: 0.4, italic: true)

        let result = FontPreview.representatives([boldItalic, bold, italic, regular, regular], limit: 6)
        #expect(result.shown == [regular, italic, bold, boldItalic])
        #expect(result.dropped == 0)
    }

    /// A multi-family pack shows every family's Regular before any family's second face,
    /// the cap holds, and the remainder is counted — never silently dropped.
    @Test func multiFamilyRoundRobinAndCap() {
        var faces: [FontPreview.Face] = []
        for family in ["A", "B", "C"] {
            faces.append(Self.face("\(family)-Thin", family: family, style: "Thin", weight: -0.6))
            faces.append(Self.face("\(family)-Regular", family: family, style: "Regular", weight: 0))
            faces.append(Self.face("\(family)-Bold", family: family, style: "Bold", weight: 0.4))
        }

        let result = FontPreview.representatives(faces, limit: 4)
        #expect(result.shown.map(\.postScriptName) == ["A-Regular", "B-Regular", "C-Regular", "A-Bold"])
        #expect(result.dropped == 5)
    }
}
