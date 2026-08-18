//
//  DoctorReport.swift
//  Brewery
//

import Foundation

/// v19 — `brew doctor --json`'s payload (cmd/doctor.rb:89-93, shape from
/// diagnostic/finding.rb:70-77): a support tier plus findings, each carrying its text, the
/// package names it affects, doc links, and a remediation whose `commands` are the
/// machine-readable fix. Decoding is deliberately tolerant — the flag is hidden and every
/// field but `text` is treated as optional — and `tier` is an int *or* a string ("unsupported").
nonisolated struct DoctorReport: Decodable, Equatable {
    struct Finding: Decodable, Equatable {
        let text: String
        let tier: TierValue?
        let affects: [String]?
        let links: [String]?
        let remediation: Remediation?
    }

    struct Remediation: Decodable, Equatable {
        let commands: [String]?
        let text: String?
    }

    /// Ruby emits the tier as an Integer or a Symbol (→ JSON string).
    enum TierValue: Decodable, Equatable {
        case number(Int)
        case label(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .label(try container.decode(String.self))
            }
        }
    }

    let tier: TierValue?
    let findings: [Finding]

    /// nil on anything that doesn't decode — the caller's raw-text fallback trigger. The
    /// bracket trim recovers JSON bracketed by stray prose lines (the outdated parser's rule).
    static func parse(_ text: String) -> DoctorReport? {
        let data = Data(text.utf8)
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start < end else { return nil }
        return try? JSONDecoder().decode(DoctorReport.self, from: data[start...end])
    }
}

/// v21 — what one remediation command becomes in the UI. A whitelist-preserving classifier:
/// exactly four shapes go native, everything else stays the copy chip — arbitrary argv remains
/// unrepresentable. Deliberately stricter than `CaveatFormat.installMentions` (which *skips*
/// unknown flags): here any flag beyond the tolerated set aborts to `.chip`, so
/// `brew install --force foo` never dresses up as a clean package row.
nonisolated enum Remedy: Equatable {
    /// Exactly `brew link <name>` — the unlinked-kegs finding's shape, one command per keg.
    case link(formula: String)
    /// Exactly `brew cleanup` — the broken-symlinks finding.
    case cleanup
    /// `brew untap <tap>…` — navigation to the Taps list, where removal owns its blocking UX.
    case untap(taps: [String])
    /// `brew install|upgrade <name>…` (only `--cask` tolerated) — navigation rows; install
    /// lives on the package's own page (the v17 rule).
    case packages(names: [String], isCask: Bool)
    /// Everything else, verbatim — sudo, git, shell redirects, force flags.
    case chip(command: String)

    static func classify(_ command: String) -> Remedy {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.first == "brew", tokens.count >= 2 else { return .chip(command: command) }

        switch tokens[1] {
        case "link":
            let rest = Array(tokens.dropFirst(2))
            guard rest.count == 1, let name = rest.first, isName(name) else {
                return .chip(command: command)
            }
            return .link(formula: name)
        case "cleanup":
            guard tokens.count == 2 else { return .chip(command: command) }
            return .cleanup
        case "untap":
            let taps = Array(tokens.dropFirst(2))
            guard !taps.isEmpty, taps.allSatisfy({ isTapName($0) }) else {
                return .chip(command: command)
            }
            return .untap(taps: taps)
        case "install", "upgrade":
            var isCask = false
            var names: [String] = []
            for token in tokens.dropFirst(2) {
                if token == "--cask" { isCask = true; continue }
                // Any other flag makes this something we must not simplify.
                guard !token.hasPrefix("-") else { return .chip(command: command) }
                guard isName(token) else { return .chip(command: command) }
                names.append(BrewClient.shortName(token))
            }
            guard !names.isEmpty else { return .chip(command: command) }
            return .packages(names: names, isCask: isCask)
        default:
            return .chip(command: command)
        }
    }

    /// A plausible package spelling — possibly tap-qualified; each path segment must pass the
    /// name charset (drops `<formula>` placeholders and shell fragments).
    private static func isName(_ token: String) -> Bool {
        let segments = token.split(separator: "/")
        return !segments.isEmpty && segments.allSatisfy { CaveatFormat.isPackageName(String($0)) }
    }

    /// Taps are exactly `owner/repo`.
    private static func isTapName(_ token: String) -> Bool {
        let segments = token.split(separator: "/")
        return segments.count == 2 && segments.allSatisfy { CaveatFormat.isPackageName(String($0)) }
    }
}
