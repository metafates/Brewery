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

    /// The faces worth a pane row, and the count of what stayed behind. The pane samples a
    /// font; it is not a specimen browser — Font Book is, one click away on Open — so the
    /// list is bounded and *representative* rather than exhaustive: deduplicated by
    /// PostScript name, each family ordered Regular → Italic → heavier weights (upright
    /// before italic at equal distance from regular), then families interleaved so every
    /// family shows its Regular before any shows its second face. A Nerd Font pack's six
    /// rows become one per family instead of six flavors of Thin.
    static func representatives(_ faces: [Face], limit: Int) -> (shown: [Face], dropped: Int) {
        var seen: Set<String> = []
        let ranked = faces
            .filter { seen.insert($0.postScriptName).inserted }
            .sorted {
                ($0.family, abs($0.weight), $0.italic ? 1 : 0, $0.style)
                    < ($1.family, abs($1.weight), $1.italic ? 1 : 0, $1.style)
            }

        var families: [String] = []
        var byFamily: [String: [Face]] = [:]
        for face in ranked {
            if byFamily[face.family] == nil { families.append(face.family) }
            byFamily[face.family, default: []].append(face)
        }

        var shown: [Face] = []
        var rank = 0
        let deepest = byFamily.values.map(\.count).max() ?? 0
        while shown.count < limit, rank < deepest {
            for family in families where rank < byFamily[family]!.count && shown.count < limit {
                shown.append(byFamily[family]![rank])
            }
            rank += 1
        }
        return (shown, ranked.count - shown.count)
    }

    /// The pane's one call: artifact names → installed files → the bounded selection.
    /// `@concurrent` is load-bearing for the same reason as `Receipts.sweep` — descriptor
    /// creation reads font files, and a plain `nonisolated async` runs on the caller's actor.
    @concurrent static func resolve(names: [String], limit: Int) async -> (shown: [Face], dropped: Int) {
        representatives(names.compactMap { fontURL(named: $0) }.flatMap(faces(at:)), limit: limit)
    }
}
