//
//  Package.swift
//  Brewery
//
//  Created by vzbarashchenko on 10.08.2026.
//

import Foundation

nonisolated enum PackageKind: String, Codable, Hashable, CaseIterable {
    case formula, cask
}

/// One entry of a formula's `conflicts_with` list, paired with its reason when the API gives one.
nonisolated struct Conflict: Codable, Hashable {
    let name: String
    let reason: String?
}

/// One catalog entry — a formula or a cask. Purely descriptive: install state lives in `AppModel`.
nonisolated struct Package: Codable, Identifiable, Hashable {
    let kind: PackageKind
    let name: String          // formula name or cask token, e.g. "visual-studio-code"
    let displayName: String?  // cask display name, e.g. "Visual Studio Code"; nil for formulae
    let desc: String?
    let homepage: String?
    let version: String
    let deprecated: Bool
    let disabled: Bool        // disabled packages cannot be installed
    let caveats: String?      // may embed a literal "$HOMEBREW_PREFIX" — see `resolvedCaveats`
    let conflicts: [Conflict] // formulae only; cask `conflicts_with` has another shape and is skipped
    let commands: [String]    // formulae only; the executables this formula installs
    let installs90d: Int?     // nil when the package is absent from the analytics files
    let license: String?      // formulae only; SPDX identifier
    let rubySourcePath: String? // repo-relative .rb path, e.g. "Formula/w/wget.rb"; nil when synthesized
    let tap: String?          // "user/repo" for third-party taps; nil = core (implied by kind)
    let tapRemote: String?    // the tap clone's git remote, for source links; nil for core

    /// Written out rather than synthesized: a `let` with an inline default drops out of the
    /// implicit memberwise init, which would break every existing `Package(kind:…)` call site.
    init(kind: PackageKind,
         name: String,
         displayName: String?,
         desc: String?,
         homepage: String?,
         version: String,
         deprecated: Bool,
         disabled: Bool,
         caveats: String? = nil,
         conflicts: [Conflict] = [],
         commands: [String] = [],
         installs90d: Int? = nil,
         license: String? = nil,
         rubySourcePath: String? = nil,
         tap: String? = nil,
         tapRemote: String? = nil) {
        self.kind = kind
        self.name = name
        self.displayName = displayName
        self.desc = desc
        self.homepage = homepage
        self.version = version
        self.deprecated = deprecated
        self.disabled = disabled
        self.caveats = caveats
        self.conflicts = conflicts
        self.commands = commands
        self.installs90d = installs90d
        self.license = license
        self.rubySourcePath = rubySourcePath
        self.tap = tap
        self.tapRemote = tapRemote
    }

    var id: String { Package.packageID(kind: kind, name: name) }

    /// Overlay dictionaries are keyed by this, so the join rule has one home.
    static func packageID(kind: PackageKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }

    var title: String { displayName ?? name }

    /// SPDX identifier, formulae only — casks carry no license in the API.
    var licenseLabel: String? { license?.isEmpty == false ? license : nil }

    /// What kind of thing this is, in a word. The icon cannot say it: once a favicon loads it
    /// replaces the SF Symbol that would have distinguished a formula from a cask.
    var kindLabel: String {
        if isFont { return "Font" }
        return kind == .formula ? "Formula" : "Cask"
    }

    /// Font casks live in homebrew/cask under a `font-` prefix; they get a glyph, never a favicon.
    var isFont: Bool { kind == .cask && name.hasPrefix("font-") }

    /// Caveats embed a literal "$HOMEBREW_PREFIX"; swap in the real prefix for display.
    func resolvedCaveats(prefix: URL?) -> String? {
        guard let caveats else { return nil }
        guard let prefix else { return caveats }
        var root = prefix.path(percentEncoded: false)
        if root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return caveats.replacingOccurrences(of: "$HOMEBREW_PREFIX", with: root)
    }

    var homepageURL: URL? { homepage.flatMap(URL.init(string:)) }

    /// The package's `.rb` definition on GitHub. The path is always tap-relative and never
    /// guessed: core paths come from the API (`ruby_source_path` — sharding schemes like
    /// `Formula/w/wget.rb` are the API's business), tap paths from the scan. Core's repo is named
    /// by the kind; a tap's is its actual git remote, and only a github.com remote gets a link —
    /// other hosts have other blob-URL schemes, and no link beats a wrong one.
    var rubySourceURL: URL? {
        guard let rubySourcePath else { return nil }
        if tap != nil {
            guard let tapRemote, tapRemote.hasPrefix("https://github.com/") else { return nil }
            return URL(string: "\(tapRemote)/blob/HEAD/\(rubySourcePath)")
        }
        let repo = kind == .formula ? "homebrew-core" : "homebrew-cask"
        return URL(string: "https://github.com/Homebrew/\(repo)/blob/HEAD/\(rubySourcePath)")
    }

    /// "wget.rb" — the link label for `rubySourceURL`.
    var rubySourceFileName: String? {
        rubySourcePath.flatMap { $0.split(separator: "/").last.map(String.init) }
    }

    /// "Which tap is this from" always has an answer: the real tap, or the core tap the kind
    /// implies. The detail sheet shows this for every package.
    var tapLabel: String {
        tap ?? (kind == .formula ? "homebrew/core" : "homebrew/cask")
    }

    /// The `user` half of a third-party tap — the identity people recognize, and all that fits
    /// in a card's caption row. nil for core, which the kind tag already implies.
    var tapOwner: String? {
        tap.flatMap { $0.split(separator: "/").first.map(String.init) }
    }

    /// Favicon of the package homepage; nil when there is no homepage host to ask about.
    var iconURL: URL? {
        guard let host = homepageURL?.host(), !host.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }
}

nonisolated struct InstalledInfo: Equatable, Hashable {
    var versions: [String]
    /// From the install receipt. A missing receipt means `true`: never hide something just
    /// because we could not explain it.
    var onRequest: Bool = true
    /// Formulae only: installed runtime dependencies as short names, `declared_directly` first.
    var dependencies: [String] = []
    /// Casks only: `.app` bundle names this cask installed, taken from its receipt.
    var apps: [String] = []
    /// From the receipt's `source.tap`, normalized: core taps and absent → nil, else "user/repo".
    /// Outranks the catalog's tap — the receipt records what was *actually* installed.
    var tap: String? = nil
}

nonisolated struct OutdatedInfo: Equatable, Hashable {
    var installed: [String]
    var current: String
    var pinned: Bool
}

nonisolated enum PackageStatus: Equatable, Hashable {
    case notInstalled
    case installed(version: String)
    case outdated(installed: String, current: String)
    case busy
}

nonisolated extension String {
    /// Casks report versions like "2.1.50,56f0a83" — only the part before the comma is meaningful to a human.
    var shortVersion: String {
        guard let comma = firstIndex(of: ",") else { return self }
        return String(self[startIndex..<comma])
    }
}
