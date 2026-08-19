//
//  CaveatFormat.swift
//  Brewery
//

import AppKit
import SwiftUI

/// Splits a caveat into its conventional blocks: prose paragraphs and indented command runs.
/// Pure and line-based — brew's caveats are hand-written text, not real Markdown, so the only
/// structure worth trusting is the one every formula actually uses.
nonisolated enum CaveatFormat {
    enum Block: Equatable {
        case text(String)
        case code(String)
    }

    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var textLines: [String] = []
        var codeLines: [String] = []

        func flushText() {
            let paragraph = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { blocks.append(.text(paragraph)) }
            textLines = []
        }
        func flushCode() {
            guard !codeLines.isEmpty else { return }
            // Strip the common indent; what remains is what the user would type.
            let indent = codeLines.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            blocks.append(.code(codeLines.map { String($0.dropFirst(indent)) }.joined(separator: "\n")))
            codeLines = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let isIndented = line.hasPrefix("  ") || line.hasPrefix("\t")
            if isBlank {
                flushText()
                flushCode()
            } else if isIndented {
                flushText()
                codeLines.append(line)
            } else {
                flushCode()
                textLines.append(line)
            }
        }
        flushText()
        flushCode()
        return blocks
    }

    /// A package a `brew install` command inside a code block points at. Pure text — resolving
    /// the name against the catalog (and dropping the page's own package) is the view's job.
    struct InstallMention: Equatable {
        let name: String   // short name — a tap-qualified spelling keeps only its last component
        let isCask: Bool   // an explicit --cask rode the same command
    }

    /// The `brew install` commands inside one code block, reduced to the packages they mention.
    /// Line-based like `blocks(of:)`: other brew verbs, non-brew commands and the prose-ish
    /// labels some blocks embed contribute nothing. `--cask` is honored in any position; other
    /// flags are skipped, and tokens that aren't plausible package names (placeholders like
    /// `<formula>`, stray continuations) are dropped.
    static func installMentions(in code: String) -> [InstallMention] {
        var mentions: [InstallMention] = []
        for line in code.split(separator: "\n") {
            // No real caveat chains commands today, but `&&`/`;`/`|` are cheap to honor.
            for segment in line.split(whereSeparator: { ";&|".contains($0) }) {
                var tokens = segment.split(whereSeparator: \.isWhitespace)[...]
                while let first = tokens.first, first == "$" || first == "sudo" {
                    tokens = tokens.dropFirst()
                }
                guard tokens.first == "brew", tokens.dropFirst().first == "install" else { continue }

                var isCask = false
                var names: [String] = []
                for token in tokens.dropFirst(2) {
                    if token.hasPrefix("-") {
                        if token == "--cask" { isCask = true }
                        continue
                    }
                    names.append(String(token.split(separator: "/").last ?? token))
                }
                for name in names where isPackageName(name) {
                    let mention = InstallMention(name: name, isCask: isCask)
                    if !mentions.contains(mention) { mentions.append(mention) }
                }
            }
        }
        return mentions
    }

    /// The charset real package names use (`lld@19`, `gtk+3`, `python-matplotlib`).
    /// Non-private since v21: the doctor remediation classifier applies the same rule.
    static func isPackageName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "@._+-".contains($0) }
    }

    /// Taps are exactly `owner/repo`, each segment in the package-name charset — one rule for
    /// the remedy classifier and the finding-format tap list.
    static func isTapName(_ token: String) -> Bool {
        let segments = token.split(separator: "/")
        return segments.count == 2 && segments.allSatisfy { isPackageName(String($0)) }
    }

    /// A prose paragraph, dressed: inline Markdown (inline-only — full parsing would collapse the
    /// newlines the text depends on; failure falls back to the raw string), code spans tinted so
    /// mono-heavy prose stops reading as noise, and bare URLs linkified — caveats cite docs pages
    /// as plain text. Native `AttributedString` for a native `Text` (v9): the base font is the
    /// view's own `.font(.callout)`, which the code spans' run-level font overrides.
    static func attributed(_ paragraph: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: paragraph,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(paragraph)

        // Code spans: the mono face plus a quiet chip, matching the code blocks' language.
        // Ranges are collected first — attribute writes coalesce runs mid-iteration.
        let codeRanges = result.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            result[range].font = .callout.monospaced()
            result[range].backgroundColor = Color(nsColor: .quaternarySystemFill)
        }

        // Bare URLs become real links (where Markdown didn't already make one). The detector
        // speaks NSRange over the plain string; both index spaces count characters, so offsets
        // carry across.
        let plain = String(result.characters)
        if let detector = linkDetector {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
                let lower = result.characters.index(
                    result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
                let upper = result.characters.index(
                    result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.upperBound))
                guard !result[lower..<upper].runs.contains(where: { $0.link != nil }) else { continue }
                result[lower..<upper].link = url
            }
        }
        return result
    }

    /// Compiled once: constructing NSDataDetector builds a regex engine, and `attributed`
    /// runs per prose block per render. Matching is thread-safe (NSRegularExpression's
    /// documented guarantee).
    private static let linkDetector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}
