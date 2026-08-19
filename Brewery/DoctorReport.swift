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
    struct Finding: Decodable, Equatable, Identifiable {
        let text: String
        let tier: TierValue?
        let affects: [String]?
        let links: [String]?
        let remediation: Remediation?

        /// Row identity for the findings list: brew emits one finding per distinct check,
        /// so the text is unique per report — and stable across a search-filter change,
        /// which positional identity was not.
        var id: String { text }
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

/// v25.1 — the structure layer over a finding's prose. `CaveatFormat.blocks` splits finding
/// text and remediation prose into paragraphs and indented code runs (brew's `inject_file_list`
/// and trust messages are exactly the two-space shape caveats use); this enum decides what a
/// code block *is*. Detection keys on sentinel lines brew's own tests pin
/// (`test/diagnostic_checks_spec.rb`), and every extractor returns nil on any surprise — the
/// view's contract is that nil degrades to a plain copyable chip, never a crash, never hidden
/// data. Parsing is presentation-only: nothing extracted here is ever executed.
nonisolated enum FindingFormat {
    enum Structure: Equatable {
        /// "/usr/bin occurs before <prefix>/bin…" + the shadowed-tools list
        /// (diagnostic.rb check_user_path_1).
        case pathShadowing
        /// "The following taps are not trusted:" + the tap list (check_untrusted_taps).
        case untrustedTaps
        case generic
    }

    static func classify(_ text: String) -> Structure {
        let firstLine = text.prefix(while: { $0 != "\n" })
        if firstLine.hasPrefix("The following taps are not trusted") { return .untrustedTaps }
        if firstLine.contains(" occurs before "),
           text.contains("The following tools exist at both paths:") { return .pathShadowing }
        return .generic
    }

    /// The shadowed-tools list inside a `.pathShadowing` finding's code block: one bare
    /// executable basename per line. Any line with whitespace, a path, or a hostile charset
    /// fails the whole block.
    static func toolList(inCode code: String) -> [String]? {
        let lines = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty,
              lines.allSatisfy({ CaveatFormat.isPackageName($0) }) else { return nil }
        return lines
    }

    /// The tap list inside an `.untrustedTaps` finding's code block: exactly `owner/repo` lines.
    static func tapList(inCode code: String) -> [String]? {
        let lines = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty, lines.allSatisfy({ line in
            let segments = line.split(separator: "/")
            return segments.count == 2 && segments.allSatisfy { CaveatFormat.isPackageName(String($0)) }
        }) else { return nil }
        return lines
    }

    /// The shadowed-package row's subtitle: which of the package's commands the PATH order
    /// affects. HIG *Lists and tables*: succinct row text — the detail slot carries the list.
    static func shadowsSubtitle(_ tools: [String]) -> String {
        "Shadowed \(tools.count == 1 ? "command" : "commands"): \(tools.joined(separator: ", "))"
    }

    /// A code block that is exactly one URL — brew's trailing "For more information, see:"
    /// shape — which should render as a link, not a copy chip.
    static func soleURL(inCode code: String) -> URL? {
        let lines = code.split(separator: "\n")
        guard lines.count == 1,
              let url = URL(string: String(lines[0]).trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// Remediation prose as blocks, deduplicated against what the finding already renders:
    /// code blocks fully covered by `commands` vanish (the commands array is the single source
    /// for chips and native rows), and a trailing "…see:" paragraph plus sole-URL block vanish
    /// when `links` repeats the URL (the links row is its one home).
    static func remediationBlocks(text: String,
                                  commands: [String],
                                  links: [String]) -> [CaveatFormat.Block] {
        let commandSet = Set(commands.map { $0.trimmingCharacters(in: .whitespaces) })
        var blocks = CaveatFormat.blocks(of: text).filter { block in
            guard case .code(let code) = block else { return true }
            let lines = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return !lines.allSatisfy { commandSet.contains($0) }
        }
        if blocks.count >= 2,
           case .code(let code) = blocks[blocks.count - 1],
           let url = soleURL(inCode: code), links.contains(url.absoluteString),
           case .text(let prose) = blocks[blocks.count - 2], prose.hasSuffix(":") {
            blocks.removeLast(2)
        }
        return blocks
    }
}

/// v25.1 — which installed package provides a shadowed tool. `<prefix>/bin/<tool>` is a
/// symlink into `../Cellar/<formula>/<version>/…` (or `…/Caskroom/<cask>/…` for cask
/// binaries), so one readlink names the provider exactly — tap formulae included, and
/// ambiguous names (`gem` → `ruby`) resolved by what is actually linked, which no
/// executables.txt index can promise.
nonisolated enum ShadowResolver {
    /// "../Cellar/ruby/3.4.1/bin/gem" → (ruby, formula); no Cellar/Caskroom marker → nil.
    static func provider(ofLinkDestination destination: String) -> (name: String, kind: PackageKind)? {
        let components = destination.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() where index + 1 < components.count {
            if component == "Cellar" { return (components[index + 1], .formula) }
            if component == "Caskroom" { return (components[index + 1], .cask) }
        }
        return nil
    }

    /// Groups tools by resolved package, preserving first-appearance order on both levels;
    /// tools the resolver can't place land in `unresolved`, shown rather than swallowed.
    static func grouped(tools: [String],
                        id: (String) -> Package.ID?) -> (groups: [(id: Package.ID, tools: [String])],
                                                         unresolved: [String]) {
        var order: [Package.ID] = []
        var byID: [Package.ID: [String]] = [:]
        var unresolved: [String] = []
        for tool in tools {
            guard let packageID = id(tool) else {
                unresolved.append(tool)
                continue
            }
            if byID[packageID] == nil { order.append(packageID) }
            byID[packageID, default: []].append(tool)
        }
        return (order.map { ($0, byID[$0] ?? []) }, unresolved)
    }

    /// One readlink per tool, off the main actor (~40 stat-cheap syscalls on a typical PATH
    /// finding). Missing links and plain files simply don't appear in the result.
    @concurrent static func readLinks(tools: [String],
                                      binDirectory: URL) async -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for tool in tools {
            let path = binDirectory.appending(path: tool, directoryHint: .notDirectory).path
            if let destination = try? fm.destinationOfSymbolicLink(atPath: path) {
                result[tool] = destination
            }
        }
        return result
    }
}

/// Everything a finding box derives from one finding before it can lay anything out: the
/// remediation commands classified and split into copy chips, Link rows and package rows
/// (deduplicated — a package already shown with a Link button must not repeat), the native
/// action flags, and the finding's prose as blocks. Pure and resolver-injected so the split
/// has tests beside `FindingFormat`'s.
nonisolated struct FindingPresentation {
    let chips: [String]
    let linkRows: [(name: String, package: Package?)]
    let packageRows: [Package]
    let offersCleanup: Bool
    let offersTaps: Bool
    let hasRemedies: Bool
    /// IDs already shown as a Link or package row — the affects list filters against these.
    let represented: Set<Package.ID>
    let structure: FindingFormat.Structure
    let textBlocks: [CaveatFormat.Block]
    let remedyBlocks: [CaveatFormat.Block]

    init(finding: DoctorReport.Finding, package: (Package.ID) -> Package?) {
        let remedies = (finding.remediation?.commands ?? []).map(Remedy.classify)
        chips = remedies.compactMap { if case .chip(let command) = $0 { command } else { nil } }
        var seen: Set<Package.ID> = []
        linkRows = remedies.compactMap { remedy -> (name: String, package: Package?)? in
            guard case .link(let formula) = remedy else { return nil }
            let id = Package.packageID(kind: .formula, name: BrewClient.shortName(formula))
            seen.insert(id)
            return (formula, package(id))
        }
        packageRows = remedies.flatMap { remedy -> [Package] in
            guard case .packages(let names, let isCask) = remedy else { return [] }
            return names.compactMap { name in
                let candidates = isCask
                    ? [Package.packageID(kind: .cask, name: name)]
                    : [Package.packageID(kind: .formula, name: name),
                       Package.packageID(kind: .cask, name: name)]
                guard let found = candidates.lazy.compactMap(package).first,
                      seen.insert(found.id).inserted else { return nil }
                return found
            }
        }
        offersCleanup = remedies.contains(.cleanup)
        offersTaps = remedies.contains { if case .untap = $0 { true } else { false } }
        hasRemedies = !remedies.isEmpty
        represented = seen
        structure = FindingFormat.classify(finding.text)
        textBlocks = CaveatFormat.blocks(of: finding.text)
        remedyBlocks = FindingFormat.remediationBlocks(
            text: finding.remediation?.text ?? "",
            commands: finding.remediation?.commands ?? [],
            links: finding.links ?? [])
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
