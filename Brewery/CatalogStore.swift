//
//  CatalogStore.swift
//  Brewery
//
//  Created by vzbarashchenko on 10.08.2026.
//

import Foundation

/// What we persist between launches: the slim catalog plus the time it was downloaded.
/// `nonisolated` so its `Codable` conformance is usable from `CatalogStore.fetch()`.
nonisolated struct CatalogCache: Codable {
    let fetchedAt: Date
    let packages: [Package]
}

enum CatalogError: Error, Equatable {
    case badStatus(code: Int)
}

/// Downloads formulae.brew.sh's full catalogs, slim-decodes them into `[Package]` and keeps a
/// compact copy on disk so normal launches never touch the network.
///
/// The whole type is `nonisolated`: the module builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// so members would otherwise be main-actor isolated and unreachable from `fetch()`.
nonisolated struct CatalogStore {
    static let formulaURL = URL(string: "https://formulae.brew.sh/api/formula.json")!
    static let caskURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    static let maxCacheAge: TimeInterval = 24 * 60 * 60

    /// Application Support/Brewery, created on demand.
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true)) ?? URL.applicationSupportDirectory
        let directory = base.appending(path: "Brewery", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var cacheURL: URL {
        supportDirectory.appending(path: "catalog.json", directoryHint: .notDirectory)
    }

    static func loadCache() -> CatalogCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CatalogCache.self, from: data)
    }

    /// Stale when older than a day — or dated in the future, which only a clock change can produce
    /// and which would otherwise pin the cache forever.
    static func isStale(_ fetchedAt: Date) -> Bool {
        !(0...maxCacheAge).contains(Date.now.timeIntervalSince(fetchedAt))
    }

    /// Downloads both catalogs concurrently, decodes them and refreshes the cache file.
    ///
    /// `@concurrent` is load-bearing: with Approachable Concurrency a plain `nonisolated async func`
    /// runs on its caller's actor, which would decode ~48 MB of JSON on the main thread.
    @concurrent static func fetch() async throws -> CatalogCache {
        async let formulaData = download(formulaURL)
        async let caskData = download(caskURL)

        var packages = try await decodeFormulae(formulaData)
        packages += try await decodeCasks(caskData)
        packages.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.name < rhs.name
        }

        let cache = CatalogCache(fetchedAt: .now, packages: packages)
        // A cache we cannot write is still a catalog we can show.
        if let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return cache
    }

    private static func download(_ url: URL) async throws -> Data {
        // We do our own 24 h staleness check; URLCache.shared is reserved for favicons.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.badStatus(code: http.statusCode)
        }
        return data
    }

    // MARK: - Slim decoding
    //
    // Both catalogs carry far more per entry than the UI needs (bottles, artifacts, variations…);
    // these throwaway types declare only the keys we read and `JSONDecoder` drops the rest.

    private struct FormulaEntry: Decodable {
        struct Versions: Decodable {
            let stable: String?
        }

        let name: String
        let desc: String?
        let homepage: String?
        let versions: Versions?
        let deprecated: Bool?
        let disabled: Bool?
    }

    private struct CaskEntry: Decodable {
        let token: String
        let name: [String]?
        let desc: String?
        let homepage: String?
        let version: String?
        let deprecated: Bool?
        let disabled: Bool?
    }

    static func decodeFormulae(_ data: Data) throws -> [Package] {
        try JSONDecoder().decode([FormulaEntry].self, from: data).map { entry in
            Package(kind: .formula,
                    name: entry.name,
                    displayName: nil,
                    desc: entry.desc,
                    homepage: entry.homepage,
                    version: entry.versions?.stable ?? "",
                    deprecated: entry.deprecated ?? false,
                    disabled: entry.disabled ?? false)
        }
    }

    static func decodeCasks(_ data: Data) throws -> [Package] {
        try JSONDecoder().decode([CaskEntry].self, from: data).map { entry in
            Package(kind: .cask,
                    name: entry.token,
                    displayName: entry.name?.first,
                    desc: entry.desc,
                    homepage: entry.homepage,
                    version: entry.version ?? "",
                    deprecated: entry.deprecated ?? false,
                    disabled: entry.disabled ?? false)
        }
    }
}
