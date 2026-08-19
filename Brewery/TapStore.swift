//
//  TapStore.swift
//  Brewery
//

import Foundation

/// One row of the Taps tab, collected during the scan — zero subprocesses.
nonisolated struct TapInfo: Equatable, Identifiable {
    var name: String          // "user/repo"
    var remote: String?       // normalized https remote, when parseable
    var formulaCount: Int     // post-graveyard: what the app actually surfaces
    var caskCount: Int
    var lastChecked: Date?    // .git/FETCH_HEAD mtime — brew update touches it per tap

    var id: String { name }
}

/// The brew 6 trust store, read directly — its writes are atomic, so a read never sees a torn
/// file, and an absent file simply means nothing is trusted. Entries for custom-remote taps are
/// stored as URLs; they fail name matching here and read as untrusted, which is the conservative
/// answer.
nonisolated struct TrustState: Equatable {
    var taps: Set<String> = []
    var trustedItems: [String] = []

    func isTrusted(_ tap: String) -> Bool {
        // Official taps are implicitly trusted and never stored (brew's tap.rb:1489-1491).
        tap.lowercased().hasPrefix("homebrew/") || taps.contains(tap.lowercased())
    }

    /// Individually trusted formulae/casks from a tap that is not trusted as a whole —
    /// the residue of qualified installs.
    func trustedItemCount(in tap: String) -> Int {
        let prefix = tap.lowercased() + "/"
        return trustedItems.count { $0.hasPrefix(prefix) }
    }

    /// v10 — whether installing `name` from `tap` would grant trust brew doesn't already
    /// have: the tap isn't trusted and no per-item entry covers this name. URL-shaped
    /// custom-remote entries fail the exact match and simply re-ask — the conservative side.
    func needsConsent(tap: String, name: String) -> Bool {
        !isTrusted(tap) && !trustedItems.contains("\(tap)/\(name)".lowercased())
    }
}

/// Everything one scan of `Library/Taps` learned: the packages, which taps produced them (the
/// guard that keeps a stale receipt from re-cloning an untapped repo), the per-tap rows, and the
/// trust store snapshot.
nonisolated struct TapScan: Equatable {
    var packages: [Package] = []
    var taps: Set<String> = []
    var infos: [TapInfo] = []
    var trust = TrustState()
}

/// Reads the third-party taps straight off disk — the directory listing *is* the tap list
/// (`brew tap` with no args is a bash iteration of exactly this directory), so no subprocess is
/// ever needed. Metadata comes from line-anchored extraction of the formula/cask DSL stanzas;
/// best-effort by design — a version that only exists implicitly (derived from `url`) is shown
/// as absent rather than guessed.
///
/// The whole type is `nonisolated` because `scan` is `@concurrent`.
nonisolated enum TapStore {
    /// Core taps are covered by the formulae.brew.sh catalog; a local git clone of either
    /// (7.7k files for homebrew/cask) must not be scanned or every cask doubles.
    static let coreTaps: Set<String> = ["homebrew/core", "homebrew/cask"]

    // MARK: - Scan

    /// `repository/Library/Taps` — the *repository*, not the prefix; they differ on Intel.
    static func tapsRoot(repository: URL) -> URL {
        repository.appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Taps", directoryHint: .isDirectory)
    }

    /// One pass over every installed third-party tap. ~200 small files on a typical machine —
    /// tens of ms, and `@concurrent` keeps them off the main actor.
    ///
    /// `installed` feeds the versioned-graveyard rule: a dead `bun@0.1.10.rb` is skipped, an
    /// installed one still gets a catalog entry. `installs90d` is the qualified-key analytics
    /// subset captured by `CatalogStore`.
    @concurrent static func scan(repository: URL,
                                 installed: Set<Package.ID>,
                                 installs90d: [String: Int],
                                 environment: [String: String]) async -> TapScan {
        var result = TapScan()
        let root = tapsRoot(repository: repository)
        let fm = FileManager.default

        guard let users = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                      options: .skipsHiddenFiles) else { return result }
        for userDir in users.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let repos = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil,
                                                          options: .skipsHiddenFiles) else { continue }
            for repoDir in repos.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let tap = tapName(user: userDir.lastPathComponent,
                                        repoDirectory: repoDir.lastPathComponent),
                      !coreTaps.contains(tap) else { continue }
                result.taps.insert(tap)
                let packages = packages(of: tap, at: repoDir,
                                        installed: installed, installs90d: installs90d)
                result.packages += packages
                result.infos.append(TapInfo(
                    name: tap,
                    remote: remoteURL(of: repoDir),
                    formulaCount: packages.count { $0.kind == .formula },
                    caskCount: packages.count { $0.kind == .cask },
                    lastChecked: fetchHeadDate(of: repoDir)))
            }
        }
        result.trust = TrustStore.read(environment: environment)
        return result
    }

    /// When brew last checked this tap for updates: `brew update` touches FETCH_HEAD per tap.
    static func fetchHeadDate(of tapDirectory: URL) -> Date? {
        let fetchHead = tapDirectory.appending(path: ".git", directoryHint: .isDirectory)
            .appending(path: "FETCH_HEAD", directoryHint: .notDirectory)
        return (try? FileManager.default.attributesOfItem(atPath: fetchHead.path))?[.modificationDate] as? Date
    }

    /// `<user>/homebrew-<repo>` → `user/repo`, lowercased — brew's own naming rule. A directory
    /// without the `homebrew-` prefix is not a tap clone and yields nil.
    static func tapName(user: String, repoDirectory: String) -> String? {
        let repo = repoDirectory.lowercased()
        guard repo.hasPrefix("homebrew-") else { return nil }
        return "\(user.lowercased())/\(repo.dropFirst("homebrew-".count))"
    }

    private static func packages(of tap: String, at directory: URL,
                                 installed: Set<Package.ID>,
                                 installs90d: [String: Int]) -> [Package] {
        let remote = remoteURL(of: directory)
        var packages: [Package] = []

        func collect(_ kind: PackageKind, _ files: [URL], _ parse: (String) -> ParsedDefinition?) {
            for file in graveyarded(files, kind: kind, installed: installed) {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let parsed = parse(text) else { continue }
                packages.append(package(kind: kind, file: file, parsed: parsed, tap: tap,
                                        remote: remote, tapRoot: directory, installs90d: installs90d))
            }
        }
        collect(.formula, formulaFiles(at: directory), parseFormula)
        collect(.cask, caskFiles(at: directory), parseCask)

        return packages
    }

    private static func package(kind: PackageKind, file: URL, parsed: ParsedDefinition,
                                tap: String, remote: String?, tapRoot: URL,
                                installs90d: [String: Int]) -> Package {
        let name = file.deletingPathExtension().lastPathComponent
        let sourcePath = file.path.replacingOccurrences(of: tapRoot.path + "/", with: "")
        return Package(kind: kind,
                       name: name,
                       displayName: parsed.displayName,
                       desc: parsed.desc,
                       homepage: parsed.homepage,
                       version: parsed.version ?? "",
                       deprecated: parsed.deprecated,
                       disabled: parsed.disabled,
                       installs90d: installs90d["\(tap)/\(name)"],
                       license: parsed.license,
                       rubySourcePath: sourcePath,
                       tap: tap,
                       tapRemote: remote,
                       artifacts: kind == .cask ? parsed.artifacts : [])
    }

    // MARK: - File discovery

    /// Brew's rule (`tap.rb`): the formula dir is the FIRST EXISTING of `Formula/`,
    /// `HomebrewFormula/`, tap root — never a union. The first two are globbed recursively
    /// (third-party sharding is allowed); the root fallback takes top-level files only, so a
    /// tap's commands and casks are not misread as formulae.
    static func formulaFiles(at directory: URL) -> [URL] {
        let fm = FileManager.default
        for sub in ["Formula", "HomebrewFormula"] {
            let dir = directory.appending(path: sub, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return rubyFiles(under: dir)
            }
        }
        let topLevel = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                    options: .skipsHiddenFiles)) ?? []
        return dedupedByBasename(topLevel.filter { $0.pathExtension == "rb" })
    }

    /// Casks always live under `Casks/`, recursively.
    static func caskFiles(at directory: URL) -> [URL] {
        rubyFiles(under: directory.appending(path: "Casks", directoryHint: .isDirectory))
    }

    private static func rubyFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: nil,
                                                          options: .skipsHiddenFiles) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "rb" {
            files.append(url)
        }
        return dedupedByBasename(files)
    }

    /// Two files with one basename in a sharded dir: brew keeps the longer path. Output sorted by
    /// basename so a scan is deterministic and cheap to compare against the previous one.
    private static func dedupedByBasename(_ files: [URL]) -> [URL] {
        var byName: [String: URL] = [:]
        for file in files {
            let name = file.lastPathComponent
            if let existing = byName[name], existing.path.count >= file.path.count { continue }
            byName[name] = file
        }
        return byName.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The graveyard rule: `bun@0.1.10.rb` next to `bun.rb` is a dead old version (oven-sh/bun
    /// ships 165 of them) and would bury search — skip it unless that exact name is installed.
    /// Core's curated `python@3.12`-style entries never pass through here.
    static func graveyarded(_ files: [URL], kind: PackageKind, installed: Set<Package.ID>) -> [URL] {
        let names = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        return files.filter { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard let at = name.firstIndex(of: "@") else { return true }
            let base = String(name[name.startIndex..<at])
            guard names.contains(base) else { return true }
            return installed.contains(Package.packageID(kind: kind, name: name))
        }
    }

    // MARK: - Definition parsing

    struct ParsedDefinition: Equatable {
        var desc: String?
        var homepage: String?
        var version: String?
        var license: String?
        var displayName: String?   // casks only: the first `name "…"` stanza
        var apps: [String] = []    // casks only: every `app "…"` stanza
        var binaries: [String] = [] // casks only: every `binary "…"` stanza, basenames
        var deprecated = false
        var disabled = false

        /// The payload in `CaskArtifact` form — apps first, then commands, matching the catalog.
        var artifacts: [CaskArtifact] {
            var result: [CaskArtifact] = []
            if !apps.isEmpty { result.append(CaskArtifact(kind: .app, names: apps)) }
            if !binaries.isEmpty { result.append(CaskArtifact(kind: .binary, names: binaries)) }
            return result
        }
    }

    /// nil unless the file declares `class … < Formula` — a stray root-level Ruby file (release
    /// scripts, generators) must not become a card.
    static func parseFormula(_ text: String) -> ParsedDefinition? {
        var sawClass = false
        let parsed = parse(text, isDefinition: { line in
            if line.hasPrefix("class "), line.contains("< Formula") { return true }
            return false
        }, sawDefinition: &sawClass)
        return sawClass ? parsed : nil
    }

    /// nil unless the file opens a `cask "…"` block.
    static func parseCask(_ text: String) -> ParsedDefinition? {
        var sawCask = false
        let parsed = parse(text, isDefinition: { line in
            line.hasPrefix("cask \"") || line.hasPrefix("cask '")
        }, sawDefinition: &sawCask)
        return sawCask ? parsed : nil
    }

    /// One pass over the lines; first match per field wins. Line-anchored on purpose: a `url`
    /// containing `#{version}` or a livecheck block must never populate a field.
    private static func parse(_ text: String,
                              isDefinition: (Substring) -> Bool,
                              sawDefinition: inout Bool) -> ParsedDefinition {
        var result = ParsedDefinition()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            if !sawDefinition, isDefinition(line) { sawDefinition = true }

            if result.desc == nil, line.hasPrefix("desc ") {
                result.desc = quoted(line)
            } else if result.homepage == nil, line.hasPrefix("homepage ") {
                result.homepage = quoted(line)
            } else if result.version == nil, line.hasPrefix("version ") {
                // `version :latest` and friends carry no literal — absent is the honest answer.
                result.version = quoted(line)
            } else if result.license == nil, line.hasPrefix("license ") {
                // Non-string forms (`:public_domain`, `"X" => {…}` compounds) keep the first
                // quoted identifier or stay absent.
                result.license = quoted(line)
            } else if result.displayName == nil, line.hasPrefix("name ") {
                result.displayName = quoted(line)
            } else if line.hasPrefix("app ") {
                // Every stanza, not the first: a cask can ship several apps.
                if let app = quoted(line) { result.apps.append(app) }
            } else if line.hasPrefix("binary ") {
                // The stanza names a path inside the staged download; the command is its basename.
                if let binary = quoted(line)?.split(separator: "/").last.map(String.init) {
                    result.binaries.append(binary)
                }
            } else if line.hasPrefix("deprecate!") {
                result.deprecated = true
            } else if line.hasPrefix("disable!") {
                result.disabled = true
            }
        }
        return result
    }

    /// The first double-quoted string on the line, `\"` and `\\` unescaped. nil when there is none.
    static func quoted(_ line: Substring) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        var value = ""
        var index = line.index(after: open)
        while index < line.endIndex {
            let character = line[index]
            if character == "\\", line.index(after: index) < line.endIndex {
                index = line.index(after: index)
                value.append(line[index])
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }
        return nil
    }

    // MARK: - Trust

    /// Reads brew 6's trust store. Pure parsing is split out for tests. v25 — the path follows
    /// brew's own resolution (bin/brew:163-170, trust.rb:27-34): `$XDG_CONFIG_HOME/homebrew`,
    /// else `$HOMEBREW_XDG_CONFIG_HOME/homebrew`, else `~/.homebrew` — evaluated against the
    /// same environment the brew children get, so Taps and Checkup can never disagree about
    /// trust again. The two historical locations stay as deduped fallback probes for the
    /// capture-failed case: reading a file brew would also read is never wrong here, absence
    /// just renders as untrusted.
    enum TrustStore {
        static func candidates(environment: [String: String], home: URL) -> [URL] {
            var result: [URL] = []
            if let xdg = environment["XDG_CONFIG_HOME"] {
                result.append(URL(filePath: xdg).appending(path: "homebrew/trust.json"))
            } else if let xdg = environment["HOMEBREW_XDG_CONFIG_HOME"] {
                result.append(URL(filePath: xdg).appending(path: "homebrew/trust.json"))
            } else {
                result.append(home.appending(path: ".homebrew/trust.json"))
            }
            for probe in [home.appending(path: ".config/homebrew/trust.json"),
                          home.appending(path: ".homebrew/trust.json")]
            where !result.contains(where: { $0.path == probe.path }) {
                result.append(probe)
            }
            return result
        }

        static func read(environment: [String: String]) -> TrustState {
            for url in candidates(environment: environment,
                                  home: FileManager.default.homeDirectoryForCurrentUser) {
                if let data = try? Data(contentsOf: url) {
                    return parse(data)
                }
            }
            return TrustState()
        }

        /// Keys per brew's `SETTING_KEYS`; values arrive lowercased but are folded again here —
        /// matching is the one thing this store must never get wrong. A malformed file reads as
        /// nothing trusted, exactly like brew's own defensive parse.
        static func parse(_ data: Data) -> TrustState {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return TrustState() }
            func strings(_ key: String) -> [String] {
                ((dictionary[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
            }
            return TrustState(
                taps: Set(strings("trustedtaps")),
                trustedItems: strings("trustedformulae") + strings("trustedcasks") + strings("trustedcommands"))
        }
    }

    // MARK: - Remote

    /// The tap's upstream, from `.git/config` — read, never assumed: custom remotes exist.
    /// ponytail: takes the first `url =` line rather than tracking INI sections; origin is
    /// written first by clone, which is what `brew tap` runs. Upgrade path: a real section parser.
    static func remoteURL(of tapDirectory: URL) -> String? {
        let config = tapDirectory.appending(path: ".git", directoryHint: .isDirectory)
            .appending(path: "config", directoryHint: .notDirectory)
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("url") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return normalizedRemote(value)
        }
        return nil
    }

    /// `git@github.com:user/repo.git` and `https://…/repo.git` both become a plain https URL a
    /// blob link can hang off; anything unrecognizable passes through untouched (the source-link
    /// builder separately requires a github.com host).
    static func normalizedRemote(_ value: String) -> String? {
        var remote = value
        if remote.hasSuffix(".git") { remote.removeLast(".git".count) }
        if remote.hasPrefix("git@") {
            // git@host:path → https://host/path
            let stripped = remote.dropFirst("git@".count)
            guard let colon = stripped.firstIndex(of: ":") else { return remote }
            remote = "https://\(stripped[stripped.startIndex..<colon])/\(stripped[stripped.index(after: colon)...])"
        }
        return remote.isEmpty ? nil : remote
    }
}
