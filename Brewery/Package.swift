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

/// What a cask puts on the machine, aggregated by kind — the payload half of the API's
/// `artifacts` array. Plumbing (zap, uninstall, flight steps, completions, manpages) is
/// deliberately absent: this answers "what do I get", not "how does brew clean up".
nonisolated struct CaskArtifact: Codable, Hashable {
    let kind: Kind
    let names: [String]

    /// Raw values are the JSON keys. The order here is the display order: the headline payload
    /// first, then the system add-ons.
    enum Kind: String, Codable, CaseIterable {
        case app
        case suite
        case binary
        case pkg
        case installer
        case font
        case qlplugin
        case prefpane = "prefpane"
        case screenSaver = "screen_saver"
        case dictionary
        case inputMethod = "input_method"
        case internetPlugin = "internet_plugin"
        case keyboardLayout = "keyboard_layout"
        case mdimporter
        case colorpicker
        case audioUnitPlugin = "audio_unit_plugin"
        case vstPlugin = "vst_plugin"
        case vst3Plugin = "vst3_plugin"
        case service

        /// Singular/plural handled by the caller via `names.count`.
        var label: String {
            switch self {
            case .app: "App"
            case .suite: "Suite"
            case .binary: "Commands"   // the same concept a formula's Commands section names
            case .pkg, .installer: "Installer"
            case .font: "Fonts"
            case .qlplugin: "Quick Look"
            case .prefpane: "Preference Pane"
            case .screenSaver: "Screen Saver"
            case .dictionary: "Dictionary"
            case .inputMethod: "Input Method"
            case .internetPlugin: "Internet Plugin"
            case .keyboardLayout: "Keyboard Layout"
            case .mdimporter: "Spotlight Importer"
            case .colorpicker: "Color Picker"
            case .audioUnitPlugin: "Audio Unit"
            case .vstPlugin: "VST Plugin"
            case .vst3Plugin: "VST 3 Plugin"
            case .service: "Service"
            }
        }

        var symbol: String {
            switch self {
            case .app, .suite: "macwindow"
            case .binary: "terminal"
            case .pkg, .installer: "shippingbox"
            case .font: "textformat"
            case .qlplugin: "eye"
            case .prefpane: "gearshape"
            case .screenSaver: "sparkles.tv"
            case .dictionary: "character.book.closed"
            case .inputMethod: "keyboard"
            case .internetPlugin: "network"
            case .keyboardLayout: "keyboard"
            case .mdimporter: "magnifyingglass"
            case .colorpicker: "eyedropper"
            case .audioUnitPlugin, .vstPlugin, .vst3Plugin: "waveform"
            case .service: "gearshape.2"
            }
        }

        /// Commands read as code; everything else is a display name.
        var isMonospaced: Bool { self == .binary }
    }
}

/// A formula's background service, slimmed from the API's `service` block to what the UI says.
/// Absent keys mean default (`compact_blank` on brew's side), hence the defaults here.
nonisolated struct ServiceDefinition: Codable, Hashable {
    var run: [String] = []      // the service's argv; string-or-array in the API
    var runType: String?        // "immediate" | "interval" | "cron"
    var interval: Int?          // seconds, when runType == "interval"
    var cron: String?           // when runType == "cron"
    var keepAlive = false       // any true value inside the keep_alive object
    var requireRoot = false     // started as a user it warns, proceeds and fails later
    var logPath: String?
    var sockets: [String] = []  // "tcp://127.0.0.1:6379" — the Ports row

    /// "Runs continuously", "Every 5 minutes", "Scheduled: 0 * * * *" — plus the keep-alive
    /// promise, which is the part a user actually cares about.
    var scheduleLabel: String {
        var label: String
        switch runType {
        case "interval":
            if let interval, interval > 0 {
                let measurement = Duration.seconds(interval)
                label = "Every \(measurement.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))"
            } else {
                label = "Runs at intervals"
            }
        case "cron":
            label = cron.map { "Scheduled: \($0)" } ?? "Scheduled"
        default:
            label = "Runs continuously"
        }
        if keepAlive { label += " · restarts if it stops" }
        return label
    }

    /// "tcp://127.0.0.1:6379" → "127.0.0.1:6379" — the scheme is launchd plumbing.
    var ports: [String] {
        sockets.map { socket in
            socket.range(of: "://").map { String(socket[$0.upperBound...]) } ?? socket
        }
    }
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
    let artifacts: [CaskArtifact] // casks only; payload artifacts aggregated by kind
    let service: ServiceDefinition? // formulae only; nil = defines no background service

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
         tapRemote: String? = nil,
         artifacts: [CaskArtifact] = [],
         service: ServiceDefinition? = nil) {
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
        self.artifacts = artifacts
        self.service = service
    }

    var id: String { Package.packageID(kind: kind, name: name) }

    /// Overlay dictionaries are keyed by this, so the join rule has one home.
    static func packageID(kind: PackageKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }

    var title: String { displayName ?? name }

    /// SPDX identifier, formulae only — casks carry no license in the API.
    var licenseLabel: String? { license?.isEmpty == false ? license : nil }

    /// The SPDX expression split at top-level `AND` only: each element is one license the user
    /// must accept. `OR` groups are a *choice* and `(X WITH exception)` groups are one unit, so
    /// both stay whole; parentheses that merely wrap a lone component are dropped for display.
    var licenseComponents: [String] {
        guard let license else { return [] }
        var components: [String] = []
        var current = ""
        var depth = 0
        var rest = Substring(license)
        while let character = rest.first {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0, rest.hasPrefix(" AND ") {
                components.append(current)
                current = ""
                rest = rest.dropFirst(" AND ".count)
                continue
            }
            current.append(character)
            rest = rest.dropFirst()
        }
        components.append(current)
        return components
            .map { component in
                let trimmed = component.trimmingCharacters(in: .whitespaces)
                // "(Apache-2.0 WITH LLVM-exception)" reads better without its wrapper — but only
                // when the parens span the whole component, or "(A OR B" would lose a brace.
                if trimmed.hasPrefix("("), trimmed.hasSuffix(")"),
                   Self.parensBalance(trimmed.dropFirst().dropLast()) == 0 {
                    return String(trimmed.dropFirst().dropLast())
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    private static func parensBalance(_ text: Substring) -> Int {
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth < 0 { return depth }
        }
        return depth
    }

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
        caveats.map { Package.substitutingPrefix($0, prefix: prefix) }
    }

    /// The API writes a literal `$HOMEBREW_PREFIX` into caveats and service paths alike.
    static func substitutingPrefix(_ text: String, prefix: URL?) -> String {
        guard let prefix else { return text }
        var root = prefix.path(percentEncoded: false)
        if root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return text.replacingOccurrences(of: "$HOMEBREW_PREFIX", with: root)
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

/// v5 — brew's seven service states, verbatim; a string brew invents later lands in `.other`
/// rather than failing the parse.
nonisolated enum ServiceHealth: String, Equatable {
    case started, stopped, none, scheduled, error, unknown, other

    /// Loaded in launchd — what the toggle means by "on". `stopped` is loaded-with-exit-0
    /// (transient; brew deletes the plist on an explicit stop, which then reads `none`).
    var isLoaded: Bool {
        switch self {
        case .started, .scheduled, .error, .stopped: true
        case .none, .unknown, .other: false
        }
    }
}

nonisolated struct ServiceStatus: Equatable {
    var health: ServiceHealth
    var exitCode: Int?
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
