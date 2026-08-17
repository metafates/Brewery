//
//  Receipts.swift
//  Brewery
//

import Foundation

/// What one keg's `INSTALL_RECEIPT.json` tells us.
nonisolated struct Receipt: Equatable {
    var onRequest: Bool
    var dependencies: [String]   // short names, `declared_directly` entries first
    var apps: [String] = []      // cask `.app` bundle names, e.g. "Firefox.app"
    var tap: String? = nil       // v4, from `source.tap`; core taps normalized to nil
    /// v10 — `poured_from_bottle` inverted: brew's autoremove never removes a formula built
    /// from source (`utils/autoremove.rb`), so the orphan report must not claim it would.
    /// Absent or unreadable counts as built-from-source — the side that under-reports.
    var builtFromSource: Bool = true
    /// v11 — the receipt's `time` (unix seconds; formula and cask receipts alike), for the
    /// Date Installed sort. nil sorts last: a keg with no receipt has no date to claim.
    var installedAt: Date? = nil
    /// v15 — casks only: `uninstall_artifacts` names a `zap` stanza, so `--zap` would do more
    /// than plain uninstall. Gates the dialog's second destructive tier.
    var hasZap: Bool = false
}

/// Reads Homebrew's per-keg install receipts. They answer both of v2's questions — "did the user
/// ask for this?" and "what does it pull in?" — as plain local file reads, so no `brew deps` /
/// `brew uses` subprocess (Ruby startup per call) is needed.
///
/// The whole type is `nonisolated` because `sweep` is `@concurrent`.
nonisolated enum Receipts {
    /// Default when a keg has no readable receipt: visible, no known dependencies. Deliberately
    /// different from a receipt that exists but omits `installed_on_request` (that one is `false`).
    static let missing = Receipt(onRequest: true, dependencies: [])

    static let fileName = "INSTALL_RECEIPT.json"

    // MARK: - Parsing

    /// Pure parser over one receipt file's bytes. Never throws — an unexpected receipt degrades to
    /// a sensible default rather than losing the package.
    static func parse(_ data: Data) -> Receipt {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Undecodable bytes are as good as no file at all: we learned nothing, so stay visible.
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return missing }

        // brew's own rule: an absent `installed_on_request` in an existing receipt means false
        // (`tab.rb`) — the keg came in as somebody else's dependency.
        return Receipt(onRequest: payload.installedOnRequest ?? false,
                       dependencies: ordered(payload.runtimeDependencies?.entries ?? []),
                       apps: payload.uninstallArtifacts?.flatMap { $0.app ?? [] } ?? [],
                       tap: normalizedTap(payload.source?.tap),
                       builtFromSource: payload.pouredFromBottle != true,
                       installedAt: payload.time.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                       hasZap: payload.uninstallArtifacts?.contains { $0.zap } ?? false)
    }

    /// Receipts say `homebrew/core`/`homebrew/cask` for core installs; folding those to nil keeps
    /// "nil = core" true everywhere — otherwise every core upgrade would get tap-qualified.
    static func normalizedTap(_ tap: String?) -> String? {
        guard let tap, !tap.isEmpty, !TapStore.coreTaps.contains(tap) else { return nil }
        return tap
    }

    /// `declared_directly` first, receipt order preserved within each group, deduplicated.
    private static func ordered(_ entries: [Payload.Dependency]) -> [String] {
        var seen: Set<String> = []
        var direct: [String] = []
        var indirect: [String] = []
        for entry in entries {
            guard let fullName = entry.fullName else { continue }
            let name = BrewClient.shortName(fullName)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            if entry.declaredDirectly == true {
                direct.append(name)
            } else {
                indirect.append(name)
            }
        }
        return direct + indirect
    }

    private struct Payload: Decodable {
        struct Dependency: Decodable {
            let fullName: String?
            let declaredDirectly: Bool?
        }

        /// Formula receipts store `runtime_dependencies` as an array of entries; cask receipts
        /// store an object (observed live: `{}`). Both must decode, so an unexpected shape simply
        /// yields no dependencies.
        struct Dependencies: Decodable {
            let entries: [Dependency]

            init(from decoder: any Decoder) throws {
                entries = (try? [Dependency](from: decoder)) ?? []
            }
        }

        /// A cask receipt records what it would have to undo, and the `app` entries in it name the
        /// bundles the cask actually put on disk. Every other artifact kind decodes to nil `app`.
        struct Artifact: Decodable {
            let app: [String]?
            /// v15 — presence of a `zap` key, whatever its value shape: the stanza's existence is
            /// the fact wanted, and its payload mixes strings with objects.
            let zap: Bool

            init(from decoder: any Decoder) throws {
                // Entries are heterogeneous — `{"app": [...]}`, `{"binary": [...]}`, `{"zap": [...]}`
                // — and some hold arrays mixing strings with objects. Only the string form is wanted.
                let container = try? decoder.container(keyedBy: CodingKeys.self)
                app = try? container?.decodeIfPresent([String].self, forKey: .app)
                zap = container?.contains(.zap) ?? false
            }

            private enum CodingKeys: String, CodingKey { case app, zap }
        }

        struct Source: Decodable {
            let tap: String?
        }

        let installedOnRequest: Bool?
        let runtimeDependencies: Dependencies?
        let uninstallArtifacts: [Artifact]?
        let source: Source?
        let pouredFromBottle: Bool?
        let time: Int?
    }

    // MARK: - Sweep

    /// `Cellar/<name>/<version>/INSTALL_RECEIPT.json` for formulae,
    /// `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` for casks.
    static func receiptURL(prefix: URL, kind: PackageKind, name: String, version: String) -> URL {
        switch kind {
        case .formula:
            prefix.appending(path: "Cellar", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
                .appending(path: version, directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory)
        case .cask:
            prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
                .appending(path: ".metadata", directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory)
        }
    }

    /// One receipt per installed keg (~350 small files, tens of ms). Dependency lists are pruned
    /// against the live installed set: a receipt is a snapshot and can still name a keg that is
    /// gone.
    ///
    /// `@concurrent` is load-bearing: with Approachable Concurrency a plain `nonisolated async
    /// func` runs on its caller's actor, which would put every one of those reads on the main
    /// thread.
    @concurrent static func sweep(prefix: URL,
                                  installed: [Package.ID: InstalledInfo]) async -> [Package.ID: Receipt] {
        var result: [Package.ID: Receipt] = [:]
        result.reserveCapacity(installed.count)

        for (id, info) in installed {
            guard let (kind, name) = Package.components(of: id) else { continue }
            // The keg we read is the one brew listed last — the version the overlay shows.
            let url = receiptURL(prefix: prefix, kind: kind, name: name, version: info.versions.last ?? "")
            guard let data = try? Data(contentsOf: url) else {
                result[id] = missing
                continue
            }
            var receipt = parse(data)
            receipt.dependencies = receipt.dependencies.filter {
                installed[Package.packageID(kind: .formula, name: $0)] != nil
            }
            result[id] = receipt
        }
        return result
    }

    // MARK: - Launching

    /// Where a cask's app ended up. brew's `app` artifact targets `/Applications` unless the cask
    /// says otherwise, and a few target the user's own folder. Resolved at the point of use rather
    /// than cached, so a bundle deleted by hand stops being offered.
    static func appURL(named name: String) -> URL? {
        let candidates = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
        ]
        for directory in candidates {
            let url = directory.appending(path: name, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Orphans (v10)

    /// What `brew autoremove` would remove (`utils/autoremove.rb`), to the same fixpoint —
    /// removing an orphan can orphan what it depended on, so the sweep repeats until stable.
    /// Three protections mirror brew's exactly: on-request formulae stay; formulae built
    /// from source stay (brew only autoremoves bottles); and cask dependencies stay — cask
    /// receipts carry no runtime deps, so those come from the catalog's `depends_on` in
    /// `caskDependencies`, and the fixpoint protects their transitive deps for free.
    /// Pure — the same receipt data the Dependencies and Required-by rows trust.
    static func orphans(in installed: [Package.ID: InstalledInfo],
                        caskDependencies: [Package.ID: [String]] = [:]) -> Set<Package.ID> {
        var alive = installed
        while true {
            var needed: Set<Package.ID> = []
            for (id, info) in alive {
                for name in info.dependencies + (caskDependencies[id] ?? []) {
                    needed.insert(Package.packageID(kind: .formula, name: name))
                }
            }
            let doomed = alive.filter { id, info in
                id.hasPrefix("formula:") && !info.onRequest && !info.builtFromSource
                    && !needed.contains(id)
            }
            guard !doomed.isEmpty else { break }
            for id in doomed.keys { alive.removeValue(forKey: id) }
        }
        return Set(installed.keys).subtracting(alive.keys)
    }

    // MARK: - Inversion

    /// "Who requires X", inverted once from the dependency lists so the detail sheet is a
    /// dictionary lookup. Values sorted and deduplicated. Pure — no I/O.
    static func invertDependents(_ installed: [Package.ID: InstalledInfo]) -> [Package.ID: [Package.ID]] {
        var result: [Package.ID: Set<Package.ID>] = [:]
        for (id, info) in installed {
            for dependency in info.dependencies {
                result[Package.packageID(kind: .formula, name: dependency), default: []].insert(id)
            }
        }
        return result.mapValues { $0.sorted() }
    }
}
