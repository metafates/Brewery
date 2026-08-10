//
//  Receipts.swift
//  Brewery
//

import Foundation

/// What one keg's `INSTALL_RECEIPT.json` tells us.
nonisolated struct Receipt: Equatable, Hashable {
    var onRequest: Bool
    var dependencies: [String]   // short names, `declared_directly` entries first
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
                       dependencies: order(payload.runtimeDependencies?.entries ?? []))
    }

    /// `declared_directly` first, receipt order preserved within each group, deduplicated.
    private static func order(_ entries: [Payload.Dependency]) -> [String] {
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

        let installedOnRequest: Bool?
        let runtimeDependencies: Dependencies?
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
            guard let (kind, name) = components(of: id) else { continue }
            // The keg we read is the one brew listed last — the version the overlay shows.
            let url = receiptURL(prefix: prefix, kind: kind, name: name, version: info.versions.last ?? "")
            guard let data = try? Data(contentsOf: url) else {
                result[id] = missing
                continue
            }
            result[id] = parse(data)
        }

        return result.mapValues { receipt in
            var pruned = receipt
            pruned.dependencies = receipt.dependencies.filter {
                installed[Package.packageID(kind: .formula, name: $0)] != nil
            }
            return pruned
        }
    }

    /// Overlay keys are `kind:shortname`; neither formula names nor cask tokens contain a colon.
    private static func components(of id: Package.ID) -> (kind: PackageKind, name: String)? {
        guard let separator = id.firstIndex(of: ":"),
              let kind = PackageKind(rawValue: String(id[id.startIndex..<separator]))
        else { return nil }
        let name = String(id[id.index(after: separator)...])
        return name.isEmpty ? nil : (kind, name)
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
