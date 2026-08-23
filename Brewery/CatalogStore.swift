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
    /// Schema stamp. A file without it fails to decode, which `loadCache` reads as "no cache".
    let version: Int
    let fetchedAt: Date
    let packages: [Package]
    /// The tap-qualified subset of the formula analytics ("user/repo/name" keys), so the tap
    /// scan can join real install counts. Optional — an older cache decodes it as nil and tap
    /// packages go uncounted until the next daily fetch, which is why no version bump is needed.
    let tapInstalls90d: [String: Int]?
    /// Each downloaded file's ETag (keyed by URL), sent back as `If-None-Match` on the next
    /// fetch so an unchanged catalog costs a handful of 304s instead of ~48 MB and a decode.
    /// Deliberately *inside* this file, never stored beside it: a validator that outlives its
    /// payload would keep earning 304s against a cache that is gone. Optional — same additive
    /// rule as `tapInstalls90d`, no version bump.
    let etags: [String: String]?

    init(version: Int = CatalogStore.cacheVersion, fetchedAt: Date, packages: [Package],
         tapInstalls90d: [String: Int]? = nil, etags: [String: String]? = nil) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.packages = packages
        self.tapInstalls90d = tapInstalls90d
        self.etags = etags
    }
}

enum CatalogError: Error {
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
    static let executablesURL = URL(string: "https://formulae.brew.sh/api/internal/executables.txt")!
    static let formulaAnalyticsURL = URL(string: "https://formulae.brew.sh/api/analytics/install/90d.json")!
    static let caskAnalyticsURL = URL(string: "https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/90d.json")!

    static let maxCacheAge: TimeInterval = 24 * 60 * 60

    /// Bumped whenever `Package`'s shape changes; a mismatch discards the cache and re-downloads.
    static let cacheVersion = 10   // 10: deprecation dates, reasons and replacements

    /// Application Support/Brewery, created once on first use — a computed property re-ran
    /// `createDirectory` on every cache path and icon-store access.
    static let supportDirectory: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true)) ?? URL.applicationSupportDirectory
        let directory = base.appending(path: "Brewery", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var cacheURL: URL {
        supportDirectory.appending(path: "catalog.json", directoryHint: .notDirectory)
    }

    /// nil when there is no cache, when the schema stamp differs, or when decoding throws — which
    /// is exactly what an unstamped file (no `version` key) produces. Migration is a fresh download.
    /// `@concurrent` for `fetch`'s reason: the warm-launch file is ~8 MB of JSON, which a plain
    /// nonisolated func would decode inline on the main actor.
    @concurrent static func loadCache() async -> CatalogCache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data),
              cache.version == cacheVersion else { return nil }
        return cache
    }

    /// Stale when older than a day — or dated in the future, which only a clock change can produce
    /// and which would otherwise pin the cache forever.
    static func isStale(_ fetchedAt: Date) -> Bool {
        !(0...maxCacheAge).contains(Date.now.timeIntervalSince(fetchedAt))
    }

    /// One conditional download's outcome: fresh bytes (with the response's validator for the
    /// next round), or the server confirming our cached copy still stands.
    enum Fetched {
        case fresh(Data, etag: String?)
        case notModified
    }

    /// Downloads the five files concurrently, decodes them and refreshes the cache file.
    ///
    /// `@concurrent` is load-bearing: with Approachable Concurrency a plain `nonisolated async func`
    /// runs on its caller's actor, which would decode ~48 MB of JSON on the main thread.
    ///
    /// Only the two catalogs are mandatory. Commands and analytics are best effort: a 500 there
    /// empties one field, it never costs the user their catalog.
    ///
    /// Every request carries the previous cache's ETag when there is one; when nothing
    /// regenerated server-side (`canReuse`), the previous packages are reused wholesale and only
    /// `fetchedAt` moves — no download, no decode. The previous cache is read *here*, not passed
    /// in: the etags live inside the versioned cache file, so a version mismatch or decode
    /// failure discards validators and payload together, and a 304 can never be honored against
    /// a payload that is gone.
    @concurrent static func fetch() async throws -> CatalogCache {
        let previous = await loadCache()
        let etags = previous?.etags ?? [:]

        async let formulaFetch = download(formulaURL, etag: etags[formulaURL.absoluteString])
        async let caskFetch = download(caskURL, etag: etags[caskURL.absoluteString])
        async let executablesFetch = downloadOptional(executablesURL,
                                                      etag: etags[executablesURL.absoluteString])
        async let formulaAnalyticsFetch = downloadOptional(formulaAnalyticsURL,
                                                           etag: etags[formulaAnalyticsURL.absoluteString])
        async let caskAnalyticsFetch = downloadOptional(caskAnalyticsURL,
                                                        etag: etags[caskAnalyticsURL.absoluteString])

        let formula = try await formulaFetch
        let cask = try await caskFetch
        let executables = await executablesFetch
        let formulaAnalytics = await formulaAnalyticsFetch
        let caskAnalytics = await caskAnalyticsFetch

        if let previous, canReuse(mandatory: [formula, cask],
                                  optional: [executables, formulaAnalytics, caskAnalytics]) {
            // Restamping matters: `isStale` gates on `fetchedAt`, so without it every launch
            // past 24 h would re-ask despite the server just saying "unchanged".
            let refreshed = CatalogCache(fetchedAt: .now, packages: previous.packages,
                                         tapInstalls90d: previous.tapInstalls90d,
                                         etags: previous.etags)
            writeCache(refreshed)
            return refreshed
        }

        let formulaResult = try await materialize(formula, from: formulaURL)
        let caskResult = try await materialize(cask, from: caskURL)
        let executablesResult = await materializeOptional(executables, from: executablesURL)
        let formulaAnalyticsResult = await materializeOptional(formulaAnalytics, from: formulaAnalyticsURL)
        let caskAnalyticsResult = await materializeOptional(caskAnalytics, from: caskAnalyticsURL)

        let commands = executablesResult.data.map(parseExecutables) ?? [:]
        let formulaInstalls = formulaAnalyticsResult.data.map(parseFormulaAnalytics) ?? [:]
        let caskInstalls = caskAnalyticsResult.data.map(parseCaskAnalytics) ?? [:]

        var packages = try decodeFormulae(formulaResult.data, commands: commands, installs: formulaInstalls)
        packages += try decodeCasks(caskResult.data, installs: caskInstalls)
        packages.sort(by: Package.displayOrder)

        var freshEtags: [String: String] = [:]
        freshEtags[formulaURL.absoluteString] = formulaResult.etag
        freshEtags[caskURL.absoluteString] = caskResult.etag
        freshEtags[executablesURL.absoluteString] = executablesResult.etag
        freshEtags[formulaAnalyticsURL.absoluteString] = formulaAnalyticsResult.etag
        freshEtags[caskAnalyticsURL.absoluteString] = caskAnalyticsResult.etag

        // The catalog join below is by short name, so qualified analytics keys would drop out;
        // kept aside instead, they give scanned tap packages their install counts.
        let cache = CatalogCache(fetchedAt: .now, packages: packages,
                                 tapInstalls90d: formulaInstalls.filter { $0.key.contains("/") },
                                 etags: freshEtags.isEmpty ? nil : freshEtags)
        writeCache(cache)
        return cache
    }

    /// The all-304 fast path's gate. Both mandatory files must answer `.notModified`. An
    /// optional file passes on `.notModified` *or* on failure (nil): the previous cache already
    /// holds its joined values, and keeping them beats re-decoding the world with that field
    /// emptied. Any fresh answer means the site regenerated and the full pipeline re-runs.
    static func canReuse(mandatory: [Fetched], optional: [Fetched?]) -> Bool {
        mandatory.allSatisfy { if case .notModified = $0 { true } else { false } }
            && optional.allSatisfy { if case .fresh? = $0 { false } else { true } }
    }

    /// Turns a conditional result into usable bytes. A `.notModified` outside the fast path is
    /// the mixed generation — this file matched while a sibling changed. Rare (the site
    /// regenerates all five together), so one unconditional re-request beats persisting
    /// per-file payloads the cache would otherwise need for reuse.
    private static func materialize(_ fetched: Fetched, from url: URL) async throws
        -> (data: Data, etag: String?) {
        switch fetched {
        case .fresh(let data, let etag):
            return (data, etag)
        case .notModified:
            guard case .fresh(let data, let etag) = try await download(url, etag: nil) else {
                throw CatalogError.badStatus(code: 304)
            }
            return (data, etag)
        }
    }

    private static func materializeOptional(_ fetched: Fetched?, from url: URL) async
        -> (data: Data?, etag: String?) {
        guard let fetched else { return (nil, nil) }
        return (try? await materialize(fetched, from: url)) ?? (nil, nil)
    }

    private static func download(_ url: URL, etag: String?) async throws -> Fetched {
        // We do our own 24 h staleness check; URLCache.shared is reserved for favicons. The
        // validator is ours for the same reason: with URLCache bypassed, a matching
        // If-None-Match comes back as a raw 304 rather than a transparent revalidation.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .fresh(data, etag: nil) }
        if http.statusCode == 304, etag != nil { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw CatalogError.badStatus(code: http.statusCode)
        }
        return .fresh(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    private static func downloadOptional(_ url: URL, etag: String?) async -> Fetched? {
        try? await download(url, etag: etag)
    }

    // A cache we cannot write is still a catalog we can show.
    private static func writeCache(_ cache: CatalogCache) {
        if let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Commands and analytics

    /// `executables.txt` is one line per formula, `name:cmd1 cmd2 …`. Blank and colon-less lines,
    /// and lines that list no command, are skipped.
    static func parseExecutables(_ data: Data) -> [String: [String]] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            let commands = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
            guard !name.isEmpty, !commands.isEmpty else { continue }
            result[name] = commands
        }
        return result
    }

    /// `analytics/install/90d.json` → `{"items":[{"formula":"openssl@3","count":"1,444,019"}]}`.
    /// Tap-qualified names simply never match a catalog name and drop out.
    static func parseFormulaAnalytics(_ data: Data) -> [String: Int] {
        guard let decoded = try? JSONDecoder().decode(FormulaAnalytics.self, from: data) else { return [:] }
        let pairs = decoded.items.compactMap { item in parseCount(item.count).map { (item.formula, $0) } }
        return Dictionary(pairs, uniquingKeysWith: max)
    }

    /// The cask analytics file's top-level key really is `formulae` (historical misnaming) and it
    /// is a dict keyed by token, each holding one entry.
    static func parseCaskAnalytics(_ data: Data) -> [String: Int] {
        guard let decoded = try? JSONDecoder().decode(CaskAnalytics.self, from: data) else { return [:] }
        return decoded.formulae.compactMapValues { $0.first.flatMap { parseCount($0.count) } }
    }

    /// Analytics counts arrive comma-formatted, as strings: "1,444,019".
    static func parseCount(_ text: String) -> Int? {
        Int(text.filter { $0 != "," })
    }

    /// `conflicts_with` and `conflicts_with_reasons` are parallel arrays. A length mismatch pads
    /// the reason with nil — never an out-of-bounds read — and a null element reads as no reason.
    static func zipConflicts(_ names: [String]?, _ reasons: [String?]?) -> [Conflict] {
        guard let names else { return [] }
        return names.enumerated().map { index, name in
            Conflict(name: name, reason: reasons.flatMap { index < $0.count ? $0[index] : nil })
        }
    }

    private struct FormulaAnalytics: Decodable {
        struct Item: Decodable {
            let formula: String
            let count: String
        }

        let items: [Item]
    }

    private struct CaskAnalytics: Decodable {
        struct Item: Decodable {
            let count: String
        }

        let formulae: [String: [Item]]
    }

    // MARK: - Slim decoding
    //
    // Both catalogs carry far more per entry than the UI needs (bottles, artifacts, variations…);
    // these throwaway types declare only the keys we read and `JSONDecoder` drops the rest.

    /// Decodes a value only if it has the shape we expect, and yields nil otherwise instead of
    /// throwing. One entry with a surprising shape would otherwise abort the whole 8.5k decode —
    /// which is exactly how a handful of null elements in `conflicts_with_reasons` once left the
    /// app with no catalog at all.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }

    private struct FormulaEntry: Decodable {
        struct Versions: Decodable {
            let stable: String?
        }

        let name: String
        let desc: String?
        let homepage: String?
        let versions: Versions?
        let license: Lenient<String>?
        let deprecated: Bool?
        let disabled: Bool?
        let caveats: String?
        let conflictsWith: [String]?
        /// Elements are nullable: the API expresses "conflict with no stated reason" as a `null`
        /// *inside* the array (live on `watch`, `parrot`, `rakudo*`), not as a shorter array.
        let conflictsWithReasons: [String?]?
        let rubySourcePath: String?
        let service: Lenient<ServiceEntry>?
        let deprecation: DeprecationFields?

        enum CodingKeys: String, CodingKey {
            case name, desc, homepage, versions, license, deprecated, disabled, caveats, service
            case conflictsWith = "conflicts_with"
            case conflictsWithReasons = "conflicts_with_reasons"
            case rubySourcePath = "ruby_source_path"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            desc = try container.decodeIfPresent(String.self, forKey: .desc)
            homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
            versions = try container.decodeIfPresent(Versions.self, forKey: .versions)
            license = try container.decodeIfPresent(Lenient<String>.self, forKey: .license)
            deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
            disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
            caveats = try container.decodeIfPresent(String.self, forKey: .caveats)
            conflictsWith = try container.decodeIfPresent([String].self, forKey: .conflictsWith)
            conflictsWithReasons = try container.decodeIfPresent([String?].self, forKey: .conflictsWithReasons)
            rubySourcePath = try container.decodeIfPresent(String.self, forKey: .rubySourcePath)
            service = try container.decodeIfPresent(Lenient<ServiceEntry>.self, forKey: .service)
            deprecation = try? DeprecationFields(from: decoder)
        }
    }

    /// The deprecation facts both catalogs serialize under the same flat keys
    /// (`formula.rb` / `cask.rb` `to_h`), read once here for both entry types. The fields sit
    /// flat on each entry's JSON object, so each entry's hand-written `init(from:)` passes this
    /// type the same `decoder` and it opens its own keyed view of the same object — the eight
    /// keys and their leniency (a surprising shape yields nil, never a lost entry — the
    /// conflicts lesson) are declared exactly once.
    struct DeprecationFields: Decodable {
        let deprecationDate: String?
        let deprecationReason: String?
        let disableDate: String?
        let disableReason: String?
        let deprecationReplacementFormula: String?
        let deprecationReplacementCask: String?
        let disableReplacementFormula: String?
        let disableReplacementCask: String?

        enum CodingKeys: String, CodingKey {
            case deprecationDate = "deprecation_date"
            case deprecationReason = "deprecation_reason"
            case disableDate = "disable_date"
            case disableReason = "disable_reason"
            case deprecationReplacementFormula = "deprecation_replacement_formula"
            case deprecationReplacementCask = "deprecation_replacement_cask"
            case disableReplacementFormula = "disable_replacement_formula"
            case disableReplacementCask = "disable_replacement_cask"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func lenient(_ key: CodingKeys) -> String? {
                (try? container.decodeIfPresent(Lenient<String>.self, forKey: key))??.value
            }
            deprecationDate = lenient(.deprecationDate)
            deprecationReason = lenient(.deprecationReason)
            disableDate = lenient(.disableDate)
            disableReason = lenient(.disableReason)
            deprecationReplacementFormula = lenient(.deprecationReplacementFormula)
            deprecationReplacementCask = lenient(.deprecationReplacementCask)
            disableReplacementFormula = lenient(.disableReplacementFormula)
            disableReplacementCask = lenient(.disableReplacementCask)
        }

        /// The *active* state's replacement pair — disable's when disabled, else deprecation's,
        /// falling across when the active pair is empty (qt@5 mirrors the same successor into
        /// both stanzas; others name it only once).
        func replacement(disabled: Bool) -> (formula: String?, cask: String?) {
            let deprecation = (deprecationReplacementFormula, deprecationReplacementCask)
            let disable = (disableReplacementFormula, disableReplacementCask)
            let primary = disabled ? disable : deprecation
            let secondary = disabled ? deprecation : disable
            return primary == (nil, nil) ? secondary : primary
        }
    }

    /// The formula `service` block, decoded leniently field by field: `run` is a string *or* an
    /// array, `keep_alive` an object of booleans, `sockets` a string or an array — and brew's
    /// `compact_blank` means any key can be absent. One surprising formula must never cost the
    /// catalog (the `conflicts_with_reasons` lesson).
    struct ServiceEntry: Decodable {
        let run: [String]
        let runType: String?
        let interval: Int?
        let cron: String?
        let keepAlive: Bool
        let requireRoot: Bool
        let logPath: String?
        let sockets: [String]

        private struct StringOrArray: Decodable {
            let values: [String]
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let one = try? container.decode(String.self) {
                    values = [one]
                } else {
                    values = (try? container.decode([Lenient<String>].self))?.compactMap(\.value) ?? []
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case run, interval, cron, sockets
            case runType = "run_type"
            case keepAlive = "keep_alive"
            case requireRoot = "require_root"
            case logPath = "log_path"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            run = (try? container.decodeIfPresent(StringOrArray.self, forKey: .run))??.values ?? []
            runType = try? container.decodeIfPresent(String.self, forKey: .runType)
            interval = try? container.decodeIfPresent(Int.self, forKey: .interval)
            cron = try? container.decodeIfPresent(String.self, forKey: .cron)
            keepAlive = ((try? container.decodeIfPresent([String: Lenient<Bool>].self, forKey: .keepAlive))?
                .contains { $0.value.value == true }) ?? false
            requireRoot = (try? container.decodeIfPresent(Bool.self, forKey: .requireRoot)) ?? false
            logPath = try? container.decodeIfPresent(String.self, forKey: .logPath)
            sockets = (try? container.decodeIfPresent(StringOrArray.self, forKey: .sockets))??.values ?? []
        }

        var definition: ServiceDefinition {
            ServiceDefinition(run: run, runType: runType, interval: interval, cron: cron,
                              keepAlive: keepAlive, requireRoot: requireRoot,
                              logPath: logPath, sockets: sockets)
        }
    }

    private struct CaskEntry: Decodable {
        let token: String
        let name: [String]?
        let desc: String?
        let homepage: String?
        let version: String?
        let deprecated: Bool?
        let disabled: Bool?
        let caveats: String?
        let rubySourcePath: String?
        let artifacts: [ArtifactEntry]?
        let conflictsWith: Lenient<ConflictsEntry>?
        let dependsOn: Lenient<DependsOnEntry>?
        let deprecation: DeprecationFields?

        enum CodingKeys: String, CodingKey {
            case token, name, desc, homepage, version, deprecated, disabled, caveats, artifacts
            case rubySourcePath = "ruby_source_path"
            case conflictsWith = "conflicts_with"
            case dependsOn = "depends_on"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decode(String.self, forKey: .token)
            name = try container.decodeIfPresent([String].self, forKey: .name)
            desc = try container.decodeIfPresent(String.self, forKey: .desc)
            homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
            version = try container.decodeIfPresent(String.self, forKey: .version)
            deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
            disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
            caveats = try container.decodeIfPresent(String.self, forKey: .caveats)
            rubySourcePath = try container.decodeIfPresent(String.self, forKey: .rubySourcePath)
            artifacts = try container.decodeIfPresent([ArtifactEntry].self, forKey: .artifacts)
            conflictsWith = try container.decodeIfPresent(Lenient<ConflictsEntry>.self, forKey: .conflictsWith)
            dependsOn = try container.decodeIfPresent(Lenient<DependsOnEntry>.self, forKey: .dependsOn)
            deprecation = try? DeprecationFields(from: decoder)
        }
    }

    /// A cask's `depends_on` object; only the `formula` list matters here — it names the
    /// formulae this cask keeps alive, which the orphan report must respect the way brew's
    /// autoremove does. Lenient at both levels: an odd shape yields no deps, never no cask.
    struct DependsOnEntry: Decodable {
        let formula: [String]

        private enum CodingKeys: String, CodingKey { case formula }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formula = ((try? container.decode([Lenient<String>].self, forKey: .formula)) ?? [])
                .compactMap(\.value)
        }
    }

    /// A cask's `conflicts_with` is an object, not the formula's parallel arrays, and brew 6's
    /// DSL accepts only the `cask` key (`cask/dsl/conflicts_with.rb:12`) — entries are cask
    /// tokens, and reasons don't exist. Wrapped `Lenient` at the field: an odd shape yields no
    /// conflicts, never no cask.
    struct ConflictsEntry: Decodable {
        let cask: [String]

        private enum CodingKeys: String, CodingKey { case cask }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cask = ((try? container.decode([Lenient<String>].self, forKey: .cask)) ?? [])
                .compactMap(\.value)
        }
    }

    /// One element of a cask's `artifacts` array: a single-key object — `{"app": ["iTerm.app"],
    /// "target": "/Applications/iTerm.app"}` — whose key names the artifact kind. Payload kinds
    /// decode; plumbing (`zap`, `uninstall`, flight steps, completions, manpages) and unknown
    /// kinds yield nil and drop out. The meaningful display name is the basename of the sibling
    /// `target` when there is one — for binaries the source is a `$APPDIR/…` path and the target
    /// is what lands on `PATH` — else of each source string. Inline `{"target": …}` objects mixed
    /// into the arrays (docker-desktop) are skipped; their entries carry a sibling target anyway.
    struct ArtifactEntry: Decodable {
        let kind: CaskArtifact.Kind?
        let names: [String]

        private struct DynamicKey: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            let target = DynamicKey(stringValue: "target").flatMap {
                try? container.decodeIfPresent(String.self, forKey: $0)
            }

            for key in container.allKeys {
                guard let found = CaskArtifact.Kind(rawValue: key.stringValue) else { continue }
                let sources = ((try? container.decode([Lenient<String>].self, forKey: key)) ?? [])
                    .compactMap(\.value)
                kind = found
                if let target {
                    names = [Self.basename(target)]
                } else {
                    names = sources.map(Self.basename)
                }
                return
            }
            kind = nil
            names = []
        }

        private static func basename(_ path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    /// Groups the payload entries by kind in `Kind`'s declaration order — the display order —
    /// deduplicating names.
    static func aggregateArtifacts(_ entries: [ArtifactEntry]) -> [CaskArtifact] {
        var byKind: [CaskArtifact.Kind: [String]] = [:]
        var seen: Set<String> = []
        for entry in entries {
            guard let kind = entry.kind, !entry.names.isEmpty else { continue }
            for name in entry.names where seen.insert("\(kind.rawValue):\(name)").inserted {
                byKind[kind, default: []].append(name)
            }
        }
        return CaskArtifact.Kind.allCases.compactMap { kind in
            byKind[kind].map { CaskArtifact(kind: kind, names: $0) }
        }
    }

    static func decodeFormulae(_ data: Data,
                               commands: [String: [String]] = [:],
                               installs: [String: Int] = [:]) throws -> [Package] {
        try JSONDecoder().decode([FormulaEntry].self, from: data).map { entry in
            var package = Package(kind: .formula,
                                  name: entry.name,
                                  displayName: nil,
                                  desc: entry.desc,
                                  homepage: entry.homepage,
                                  version: entry.versions?.stable ?? "",
                                  deprecated: entry.deprecated ?? false,
                                  disabled: entry.disabled ?? false,
                                  caveats: entry.caveats,
                                  conflicts: zipConflicts(entry.conflictsWith, entry.conflictsWithReasons),
                                  commands: commands[entry.name] ?? [],
                                  installs90d: installs[entry.name],
                                  license: entry.license?.value,
                                  rubySourcePath: entry.rubySourcePath,
                                  service: entry.service?.value?.definition)
            applyDeprecation(entry.deprecation, to: &package)
            return package
        }
    }

    static func decodeCasks(_ data: Data, installs: [String: Int] = [:]) throws -> [Package] {
        try JSONDecoder().decode([CaskEntry].self, from: data).map { entry in
            var package = Package(kind: .cask,
                                  name: entry.token,
                                  displayName: entry.name?.first,
                                  desc: entry.desc,
                                  homepage: entry.homepage,
                                  version: entry.version ?? "",
                                  deprecated: entry.deprecated ?? false,
                                  disabled: entry.disabled ?? false,
                                  caveats: entry.caveats,
                                  conflicts: (entry.conflictsWith?.value?.cask ?? [])
                                      .map { Conflict(name: $0, reason: nil, kind: .cask) },
                                  installs90d: installs[entry.token],
                                  rubySourcePath: entry.rubySourcePath,
                                  artifacts: aggregateArtifacts(entry.artifacts ?? []),
                                  caskDependencies: entry.dependsOn?.value?.formula ?? [])
            applyDeprecation(entry.deprecation, to: &package)
            return package
        }
    }

    /// The dates and reasons ride only on packages that are actually marked — a fresh package
    /// with a leftover `deprecation_date` (it happens: stanzas get reverted) must not grow a
    /// banner sentence.
    private static func applyDeprecation(_ fields: DeprecationFields?, to package: inout Package) {
        guard let fields, package.needsAttention else { return }
        package.deprecationDate = fields.deprecationDate
        package.deprecationReason = fields.deprecationReason
        package.disableDate = fields.disableDate
        package.disableReason = fields.disableReason
        let replacement = fields.replacement(disabled: package.disabled)
        package.replacementFormula = replacement.formula
        package.replacementCask = replacement.cask
    }
}
