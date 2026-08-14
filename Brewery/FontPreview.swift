//
//  FontPreview.swift
//  Brewery
//

import CoreText
import Foundation

/// Resolves an installed font cask's artifact names to the faces actually on disk, so the
/// detail pane can demonstrate each face in itself. Faces come from the files, never from
/// the cask token: `CTFontManagerCreateFontDescriptorsFromURL` reads what the file really
/// contains — family, style, weight — and handles `.ttc` collections with several faces.
nonisolated enum FontPreview {
    /// One renderable face. The PostScript name is what `Font.custom` resolves — the file
    /// lives in `~/Library/Fonts`, so the system registry already knows it.
    struct Face: Equatable, Sendable, Identifiable {
        let postScriptName: String
        let family: String
        let style: String
        let weight: Double  // kCTFontWeightTrait, -1…1, 0 = regular
        let italic: Bool

        var id: String { postScriptName }
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Fonts", directoryHint: .isDirectory)

    /// Where brew put one font artifact. The artifact's *name* is a source-relative path
    /// (`ttf/Hack-Regular.ttf`); the installed file is its basename under `fontdir` —
    /// brew's `Moved` targets `fontdir/<source basename>` (`cask/artifact/relocated.rb:66`),
    /// and `fontdir` defaults to `~/Library/Fonts` (`cask/config.rb:26`).
    /// ponytail: a custom `--fontdir` install resolves nowhere and gets no preview; reading
    /// the receipt's cask config would lift that.
    static func fontURL(named name: String, in directory: URL = defaultDirectory) -> URL? {
        let basename = URL(filePath: name).lastPathComponent
        guard !basename.isEmpty else { return nil }
        let url = directory.appending(path: basename, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every face one file provides — several for a `.ttc` collection. A file CoreText
    /// cannot parse yields no faces rather than an error; the section just shows less.
    static func faces(at url: URL) -> [Face] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap { descriptor in
            guard let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !postScript.isEmpty, !family.isEmpty
            else { return nil }
            let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? ""
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let weight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            return Face(postScriptName: postScript,
                        family: family,
                        style: style,
                        weight: weight,
                        italic: symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0)
        }
    }

    /// Deduplicated (by PostScript name) and ordered for display: family, then weight
    /// ascending, then upright before italic — Font Book's Regular, Italic, Bold, Bold Italic.
    static func order(_ faces: [Face]) -> [Face] {
        var seen: Set<String> = []
        return faces
            .filter { seen.insert($0.postScriptName).inserted }
            .sorted {
                ($0.family, $0.weight, $0.italic ? 1 : 0, $0.style)
                    < ($1.family, $1.weight, $1.italic ? 1 : 0, $1.style)
            }
    }

    /// The pane's one call: artifact names → installed files → ordered faces.
    /// `@concurrent` is load-bearing for the same reason as `Receipts.sweep` — descriptor
    /// creation reads font files, and a plain `nonisolated async` runs on the caller's actor.
    @concurrent static func resolve(names: [String]) async -> [Face] {
        order(names.compactMap { fontURL(named: $0) }.flatMap(faces(at:)))
    }
}
