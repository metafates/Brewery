//
//  AppModel.swift
//  Brewery
//

import AppKit
import Foundation
import Observation

/// The single root of app state: the catalog, the install-state overlays, and the FIFO queue that
/// serializes every mutating brew invocation. Main-actor isolated like everything else, so the
/// queue needs no locks.
@Observable
final class AppModel {
    /// Core catalog + scanned tap packages, composed by `composeCatalog()`.
    private(set) var catalog: [Package] = []
    /// The formulae.brew.sh half, kept apart from the tap half so either can change alone.
    private var coreCatalog: [Package] = []
    /// The `Library/Taps` half, plus the set of scanned taps (the command-qualification guard).
    private var tapScan = TapScan()
    /// Qualified-key analytics from the catalog cache, joined into scanned tap packages.
    private var tapInstalls90d: [String: Int] = [:]
    /// Bumped on every compose. The view layer keys invalidation on this, not on `catalog.count`:
    /// a count cannot see a tap swap that nets zero.
    private(set) var catalogGeneration = 0
    /// `catalog` keyed by `Package.ID`. The detail sheet resolves one `Package` per dependency and
    /// per dependent, and a linear scan of ~16k entries per lookup (each comparison building a
    /// fresh interpolated `id`) stalls the main actor visibly on a package with many deps.
    private var catalogIndex: [Package.ID: Package] = [:]
    /// "Which packages provide this executable", from the catalog's command lists. Search consults
    /// it so `convert` finds imagemagick; the detail sheet just reads `package.commands`.
    private(set) var commandIndex: [String: [Package.ID]] = [:]
    var catalogLoading = false
    var catalogFailed = false

    /// Overlays are keyed by `Package.ID` (`kind:shortname`) and never persisted — they are
    /// under a second to re-query.
    var installed: [Package.ID: InstalledInfo] = [:]
    var outdated: [Package.ID: OutdatedInfo] = [:]

    /// "Who requires X", inverted from the receipt dependency lists and rebuilt on every refresh,
    /// in the same step as the installed overlay it is derived from.
    var dependents: [Package.ID: [Package.ID]] = [:]

    /// v5 — what `brew services list` reports, keyed by short formula name. Every installed
    /// formula that defines a service has an entry, whatever its state.
    var serviceStatuses: [String: ServiceStatus] = [:]

    var operations: [BrewOperation] = []
    var brewMissing = false

    /// ⌘R does its work in the background and used to say nothing while it did. Drives the spinning
    /// toolbar glyph, so a refresh is visibly happening rather than apparently ignored.
    private(set) var isRefreshing = false

    /// v8 — true while the inline `brew update` of the freshness rule runs. Drives the Outdated
    /// page's "Checking for updates…" states; also holds `pump()`, so a mutation enqueued
    /// mid-check starts right after it (with fresh metadata) instead of colliding with brew's
    /// exclusive update flock.
    private(set) var isCheckingForUpdates = false

    /// v8 — the newest API payload mtime, brew's "metadata last known good" (terminal updates
    /// count too). Re-stat'd on every refresh; feeds the "Last checked" caption and the
    /// staleness gate.
    private(set) var metadataCheckedAt: Date?

    /// Set once when an operation fails so the operations popover can auto-present; the view
    /// clears it after showing.
    var failureToPresent: BrewOperation?

    /// One search query per sidebar section, so queries never leak across tabs and each survives
    /// switching away and back. It lives here rather than in the view because switching sections
    /// tears the detail column down, taking any `@State` query with it.
    var queries: [SidebarSection: String] = [:]

    /// The sidebar's destination, and whether the operations popover is showing. Both are in the
    /// model rather than the view because the menu bar owns commands for them — View ▸ the five
    /// sections, View ▸ Show Operations — and a `Commands` builder can only reach app-level state.
    /// Persisted (v9): the app reopens where it was left — HIG Launching, "restore the previous
    /// state when your app restarts so people can continue where they left off". Someone who
    /// lives in Outdated should not re-navigate there every launch.
    var selection: SidebarSection? = SidebarSection(
        rawValue: UserDefaults.standard.string(forKey: "sidebar.section") ?? "") ?? .discover {
        didSet {
            if let selection { UserDefaults.standard.set(selection.rawValue, forKey: "sidebar.section") }
        }
    }
    var showOperations = false
    /// Open by default: the first card click then describes into a pane that is already laid
    /// out, instead of reflowing the whole grid to make room (Mail's reading-pane grammar —
    /// present with a No Selection placeholder until something is chosen). Hidden-or-shown
    /// persists across launches: pane visibility is personalization (HIG macOS: let people
    /// configure windows to display the views they use most), so a closed pane stays closed.
    var showInspector = UserDefaults.standard.object(forKey: "inspector.shown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "inspector.shown") }
    }

    /// Bumped by the ⌘F menu command. `ContentView` observes it and moves focus to the search
    /// field — the automatic ⌘F binding has historically been unreliable on macOS.
    private(set) var findRequests = 0

    /// Same channel for Homebrew ▸ Add Tap…: the popover is anchored to a toolbar button that only
    /// exists on the tap list, so the view has to leave any drill-down before presenting it.
    private(set) var addTapRequests = 0

    let client = BrewClient()

    private var catalogFetchedAt: Date?
    private var didBootstrap = false
    /// v8 — when the last inline `brew update` was *started*, successful or not. brew only
    /// touches the payload mtime on success, so without this an offline machine would re-attempt
    /// (and time out) on every single ⌘R; with it, once per window.
    private var lastMetadataAttempt: Date?
    private var runningTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init() {
        brewMissing = !client.isAvailable

        // UI-test seeding (`OperationsSurfaceTests`): operations exist only mid-mutation, and
        // a test must not mutate the machine, so the operations surface gets a canned queue.
        if ProcessInfo.processInfo.arguments.contains("-demo-operation") {
            let done = BrewOperation(command: .update, title: "Updating Homebrew", targetID: nil)
            done.state = .succeeded
            ["==> Updating Homebrew...",
             "Updated 2 taps (homebrew/core and homebrew/cask)."].forEach(done.append)
            let running = BrewOperation(command: .upgradeAll, title: "Updating all packages", targetID: nil)
            running.state = .running
            ["==> Upgrading 3 outdated packages:",
             "ffmpeg 9.0 -> 9.0.1, libpq 18.4 -> 18.6, ruff 0.16.2 -> 0.16.3",
             "==> Fetching downloads for: ffmpeg, libpq and ruff",
             "==> Downloading https://ghcr.io/v2/homebrew/core/ffmpeg/manifests/9.0.1",
             "==> Fetching ffmpeg",
             "==> Downloading https://ghcr.io/v2/homebrew/core/ffmpeg/blobs/sha256:2f4d",
             "==> Upgrading ffmpeg",
             "  9.0 -> 9.0.1 ",
             "==> Pouring ffmpeg--9.0.1.arm64_tahoe.bottle.tar.gz",
             "🍺  /opt/homebrew/Cellar/ffmpeg/9.0.1: 289 files, 51.3MB",
             "==> Running `brew cleanup ffmpeg`...",
             "Warning: Skipping cleanup (HOMEBREW_NO_INSTALL_CLEANUP is set).",
             "==> Upgrading libpq",
             "  18.4 -> 18.6 ",
             "==> Pouring libpq--18.6.arm64_tahoe.bottle.tar.gz"].forEach(running.append)
            // A per-package operation, so the card's cancellable busy state is reachable too.
            // First in the array — the popover renders reversed, and OperationsSurfaceTests
            // expects the upgradeAll row on top.
            let single = BrewOperation(command: .upgrade(name: "ffmpeg", cask: false),
                                       title: "Updating ffmpeg",
                                       targetID: Package.packageID(kind: .formula, name: "ffmpeg"))
            single.state = .running
            ["==> Fetching ffmpeg",
             "==> Downloading https://ghcr.io/v2/homebrew/core/ffmpeg/manifests/9.0.1"].forEach(single.append)
            operations = [single, done, running]
        }
    }

    // MARK: - Loading

    /// Cache first so the grid is populated immediately, then the installed/outdated probes and
    /// (only if the catalog is stale or absent) the download run concurrently.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        let cache = CatalogStore.loadCache()
        if let cache {
            tapInstalls90d = cache.tapInstalls90d ?? [:]
            await setCoreCatalog(cache.packages)
            catalogFetchedAt = cache.fetchedAt
        }

        let state = Task { await self.refreshState() }
        if cache.map({ CatalogStore.isStale($0.fetchedAt) }) ?? true {
            await loadCatalog()
        }
        await state.value

        // v8 — probes first (cached-metadata answers on screen in a second), then the freshness
        // rule corrects them: brew's own outdated computation runs against a cache our standing
        // HOMEBREW_NO_AUTO_UPDATE freezes, so a stale launch re-probes after one `brew update`.
        if await checkForUpdatesIfStale() {
            // The claim must wait for the answer: the flag stays up through the re-probe, or an
            // empty Outdated page says "Everything is up to date" for the second it takes the
            // fresh read to land — the exact lie v8 exists to kill. No suspension between the
            // check dropping the flag and this raising it, so no frame sees the gap; the held
            // pump costs a queued mutation only the probe's own second.
            isCheckingForUpdates = true
            defer { isCheckingForUpdates = false; pump() }
            await refreshState()
        }
    }

    /// ⌘R: re-probe brew, re-read installed/outdated, and re-run the 24 h catalog staleness check.
    func refresh() async {
        // Re-entrant refreshes would flicker the indicator and duplicate the work behind it.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        client.discover()

        // v8 — unlike bootstrap, the check runs *before* the probes: the veil is already up, and
        // one landing beats showing stale answers mid-refresh only to swap them seconds later.
        _ = await checkForUpdatesIfStale()

        let state = Task { await self.refreshState() }
        if catalogFetchedAt.map(CatalogStore.isStale) ?? true {
            await loadCatalog()
        }
        await state.value
    }

    /// The v8 freshness rule: brew's metadata must be no older than brew's own API window
    /// (450 s) before `outdated` is worth asking. An explicit `brew update` is not gated by
    /// `HOMEBREW_NO_AUTO_UPDATE` (only the auto-update path checks it), so it refreshes the API
    /// cache and tap clones even with our env set. Failure is silent by design — the probes fall
    /// back to the cached answer, exactly the pre-v8 behavior. Returns whether an update ran.
    private func checkForUpdatesIfStale() async -> Bool {
        metadataCheckedAt = client.metadataDate()
        guard client.isAvailable, !isCheckingForUpdates, !isQueueActive, metadataIsStale else {
            return false
        }
        if let attempt = lastMetadataAttempt,
           Date.now.timeIntervalSince(attempt) < BrewClient.metadataWindow {
            return false
        }
        lastMetadataAttempt = .now

        isCheckingForUpdates = true
        // The pump held while the check ran; release whatever queued up meanwhile.
        defer { isCheckingForUpdates = false; pump() }

        _ = try? await client.run(.update) { _ in }
        metadataCheckedAt = client.metadataDate()
        return true
    }

    /// Stale means older than brew's own refresh window — the freshness a terminal `brew
    /// outdated` guarantees, which makes it the parity target, not a number we invented.
    private var metadataIsStale: Bool {
        guard let date = metadataCheckedAt else { return true }
        return Date.now.timeIntervalSince(date) > BrewClient.metadataWindow
    }

    func retryCatalog() async {
        await loadCatalog()
    }

    private func loadCatalog() async {
        guard !catalogLoading else { return }
        catalogLoading = true
        catalogFailed = false
        defer { catalogLoading = false }

        do {
            let cache = try await CatalogStore.fetch()
            tapInstalls90d = cache.tapInstalls90d ?? [:]
            await setCoreCatalog(cache.packages)
            catalogFetchedAt = cache.fetchedAt
        } catch {
            // A stale catalog still beats an error screen; only a cold start with no cache fails.
            catalogFailed = catalog.isEmpty
        }
    }

    /// The core half. The catalog is published (composed) before the first suspension — the grid
    /// never waits on the command index — and awaiting the build here keeps the two paths (cache,
    /// fresh download) from landing out of order. The command index rebuilds *only* here: tap
    /// formulae carry no executables.txt data, so re-deriving a ~60k-key index on every tap
    /// rescan would be pure waste.
    private func setCoreCatalog(_ packages: [Package]) async {
        coreCatalog = packages
        composeCatalog()
        commandIndex = await Self.buildCommandIndex(packages)
    }

    /// The one writer of `catalog` and `catalogIndex`, so neither can drift from the two halves.
    /// Dedupe is deterministic: core wins core-vs-tap, and the scan's tap-alphabetical order makes
    /// the alphabetically-first tap win tap-vs-tap — the v1 accepted-collision rule, extended.
    private func composeCatalog() {
        var index = Dictionary(coreCatalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var composed = coreCatalog
        composed.reserveCapacity(coreCatalog.count + tapScan.packages.count)
        for package in tapScan.packages where index[package.id] == nil {
            index[package.id] = package
            composed.append(package)
        }
        catalog = composed
        catalogIndex = index
        catalogGeneration &+= 1
    }

    /// Inverts the per-formula command lists into "who provides this executable". ~60k names across
    /// the catalog, which is why it is `@concurrent`: a plain `nonisolated async func` would build
    /// the whole thing on the main actor. Keys keep their original case — `FuzzySearch` folds them.
    @concurrent nonisolated static func buildCommandIndex(_ packages: [Package]) async -> [String: [Package.ID]] {
        var index: [String: [Package.ID]] = [:]
        index.reserveCapacity(packages.count * 4)
        for package in packages {
            for command in package.commands {
                index[command, default: []].append(package.id)
            }
        }
        return index
    }

    /// Both reads at once — brew serializes only mutations, so concurrent reads are safe. The
    /// receipt sweep runs on the result and everything is published in one step: an overlay whose
    /// on-request flags have not landed yet would briefly show dependency-only kegs as directly
    /// installed.
    private func refreshState() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // One cheap stat per refresh keeps the "Last checked" caption honest even when the
        // update happened in a terminal.
        metadataCheckedAt = client.metadataDate()

        brewMissing = !client.isAvailable
        guard client.isAvailable else {
            installed = [:]
            outdated = [:]
            dependents = [:]
            serviceStatuses = [:]
            return
        }

        let installedTask = Task { try await self.client.listInstalled() }
        let outdatedTask = Task { try await self.client.outdated() }
        let servicesTask = Task { try await self.client.servicesList() }

        let installedResult = try? await installedTask.value
        let outdatedResult = try? await outdatedTask.value
        let servicesResult = try? await servicesTask.value

        let folded: [Package.ID: InstalledInfo]?
        if let installedResult {
            folded = await withReceipts(installedResult)
        } else {
            folded = nil
        }

        // The tap rescan rides every refresh — the session `brew update` pulls tap clones, so
        // versions can bump mid-session. It follows the installed read because the graveyard rule
        // needs the fresh keg list.
        let scan: TapScan?
        if let repository = client.repository {
            scan = await TapStore.scan(repository: repository,
                                       installed: Set((folded ?? installed).keys),
                                       installs90d: tapInstalls90d)
        } else {
            scan = nil
        }

        // A refresh started later holds the fresher answer; the sweep is slow enough that a ⌘R or a
        // post-mutation refresh can overtake this one, and a late write would mix the two.
        guard generation == refreshGeneration else { return }
        if let folded {
            installed = folded
            dependents = Receipts.invertDependents(folded)
        }
        if let outdatedResult { outdated = outdatedResult }
        if let servicesResult { serviceStatuses = servicesResult }
        // Recompose only on a real change — scans are usually identical, and an unchanged catalog
        // must not invalidate the view layer's keys.
        if let scan, scan != tapScan {
            tapScan = scan
            composeCatalog()
        }
    }

    /// Folds each keg's install receipt into its overlay entry. Nothing to read without a prefix,
    /// in which case the defaults stand (`onRequest: true` — never hide the unexplained).
    private func withReceipts(_ installed: [Package.ID: InstalledInfo]) async -> [Package.ID: InstalledInfo] {
        guard let prefix = client.prefix else { return installed }
        let receipts = await Receipts.sweep(prefix: prefix, installed: installed)

        var result = installed
        for (id, receipt) in receipts {
            result[id]?.onRequest = receipt.onRequest
            result[id]?.dependencies = receipt.dependencies
            result[id]?.apps = receipt.apps
            result[id]?.tap = receipt.tap
        }
        return result
    }

    // MARK: - Derived state

    func status(for package: Package) -> PackageStatus {
        if isBusy(package) { return .busy }
        if let info = outdated[package.id] {
            return .outdated(installed: info.installed.last ?? "", current: info.current)
        }
        if let info = installed[package.id] {
            return .installed(version: info.versions.last ?? package.version)
        }
        return .notInstalled
    }

    /// A bare `brew upgrade` touches every outdated formula and cask except the pinned ones, so a
    /// running `upgradeAll` makes all of them busy at once. Busy outlives the operation by one
    /// refresh (`awaitingRefresh`): between completion and the probes landing, the overlays still
    /// answer for the old world, and the card must not repeat that stale answer.
    private func isBusy(_ package: Package) -> Bool {
        for operation in operations where !operation.isFinished || operation.awaitingRefresh {
            if operation.targetID == package.id { return true }
            if operation.command == .upgradeAll,
               operation.state == .running || operation.awaitingRefresh,
               let info = outdated[package.id], !info.pinned {
                return true
            }
        }
        return false
    }

    /// Catalog entries that are installed, plus synthesized ones for anything installed from a tap
    /// the catalog does not cover.
    var installedPackages: [Package] {
        merged(catalog.filter { installed[$0.id] != nil },
               with: installed.mapValues { $0.versions })
    }

    /// The Installed section under the scope picker. `.all` is the full list; `.onRequest` drops the
    /// kegs that are only on disk because something else needed them.
    func installedPackages(scope: InstalledScope) -> [Package] {
        switch scope {
        case .all:
            installedPackages
        case .onRequest:
            installedPackages.filter { installed[$0.id]?.onRequest ?? true }
        }
    }

    /// Turns an overlay key back into a package for the dependency and required-by rows: the
    /// catalog when it covers it, otherwise the same synthesized entry the Installed section uses —
    /// a dependency pulled in from a tap exists only on disk.
    func package(for id: Package.ID) -> Package? {
        if let known = catalogIndex[id] { return known }
        guard let info = installed[id] else { return nil }
        return Self.synthesize(id: id, versions: info.versions)
    }

    var outdatedPackages: [Package] {
        merged(catalog.filter { outdated[$0.id] != nil },
               with: outdated.mapValues(\.installed))
    }

    /// Third-party taps are absent from formulae.brew.sh, so all we can honestly show for them is
    /// the name, the kind and the version that is on disk.
    private func merged(_ known: [Package], with versions: [Package.ID: [String]]) -> [Package] {
        var result = known
        let covered = Set(known.map(\.id))
        for (id, installedVersions) in versions where !covered.contains(id) {
            guard let package = Self.synthesize(id: id, versions: installedVersions) else { continue }
            result.append(package)
        }
        return result.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.name < rhs.name
        }
    }

    private static func synthesize(id: Package.ID, versions: [String]) -> Package? {
        guard let separator = id.firstIndex(of: ":"),
              let kind = PackageKind(rawValue: String(id[id.startIndex..<separator])) else { return nil }
        return Package(kind: kind,
                       name: String(id[id.index(after: separator)...]),
                       displayName: nil,
                       desc: nil,
                       homepage: nil,
                       version: versions.last ?? "",
                       deprecated: false,
                       disabled: false)
    }

    // MARK: - Operation queue

    /// Mutating commands only: reads never queue. Runs one at a time, FIFO, and a failure never
    /// halts or drains what is behind it.
    func enqueue(_ command: BrewCommand, title: String, targetID: Package.ID?) {
        guard command.isMutating else { return }
        // A catalog entry can never start with a dash, but brew would read one as a flag if it did.
        switch command {
        case let .install(name, _), let .upgrade(name, _),
             let .serviceStart(name), let .serviceStop(name),
             let .tap(name), let .untap(name), let .trustTap(name), let .untrustTap(name):
            guard !name.isEmpty, !name.hasPrefix("-") else { return }
        default:
            break
        }

        // v8 — auto-update is disabled on every invocation, so a package mutation must bring
        // brew's metadata in line first; but only when it actually drifted. The once-per-session
        // flag this replaces both under-updated (a days-long session updated once, then drifted)
        // and over-updated (an install a minute after the launch check paid ~5 s for a no-op).
        // Service toggles skip it — they change launchd state, not packages.
        if command.touchesPackages, !isCheckingForUpdates, !updatePending {
            metadataCheckedAt = client.metadataDate()
            if metadataIsStale {
                operations.append(BrewOperation(command: .update, title: "Updating Homebrew", targetID: nil))
            }
        }

        operations.append(BrewOperation(command: command, title: title, targetID: targetID))
        pump()
    }

    func install(_ package: Package) {
        enqueue(.install(name: qualifiedName(for: package), cask: package.kind == .cask),
                title: "Installing \(package.title)",
                targetID: package.id)
    }

    func upgrade(_ package: Package) {
        enqueue(.upgrade(name: qualifiedName(for: package), cask: package.kind == .cask),
                title: "Updating \(package.title)",
                targetID: package.id)
    }

    /// The effective tap of a package: what the receipt says was installed, else what the catalog
    /// says. The card tag, the detail row and the command line all read this one rule, so what
    /// the UI claims and what brew is told never diverge.
    func effectiveTap(for package: Package) -> String? {
        installed[package.id]?.tap ?? package.tap
    }

    /// Tap items must reach brew fully qualified: a bare short name always resolves to core
    /// (brew's API loader precedes its tap loaders), and the qualified form is also what
    /// satisfies brew 6.x's tap-trust gate. The scan-membership guard is load-bearing — a stale
    /// receipt naming a since-untapped tap would otherwise make brew clone the tap back.
    private func qualifiedName(for package: Package) -> String {
        guard let tap = effectiveTap(for: package), tapScan.taps.contains(tap) else {
            return package.name
        }
        return "\(tap)/\(package.name)"
    }

    func upgradeAll() {
        enqueue(.upgradeAll, title: "Updating all packages", targetID: nil)
    }

    // MARK: - Services (v5)

    /// The Services section's rows: exactly what brew reports as available, as packages —
    /// catalog entries where covered, synthesized otherwise. Alphabetical, like an inventory.
    var servicePackages: [Package] {
        serviceStatuses.keys
            .compactMap { package(for: Package.packageID(kind: .formula, name: $0)) }
            .sorted { $0.name < $1.name }
    }

    var runningServicesCount: Int {
        serviceStatuses.values.count { $0.health == .started }
    }

    func serviceStatus(for package: Package) -> ServiceStatus? {
        serviceStatuses[package.name]
    }

    func startService(_ package: Package) {
        enqueue(.serviceStart(name: qualifiedName(for: package)),
                title: "Starting \(package.title)",
                targetID: package.id)
    }

    func stopService(_ package: Package) {
        enqueue(.serviceStop(name: qualifiedName(for: package)),
                title: "Stopping \(package.title)",
                targetID: package.id)
    }

    // MARK: - Taps (v6)

    /// The Taps tab's rows, straight from the scan; the trust snapshot rides along.
    var tapInfos: [TapInfo] { tapScan.infos }
    var trustState: TrustState { tapScan.trust }

    /// A tap page's contents come from the scan, not the composed catalog: a tap entry that lost
    /// the core-vs-tap dedupe (bun was upstreamed into core) still belongs on *its tap's* page.
    func tapPackages(for tap: String) -> [Package] {
        tapScan.packages.filter { $0.tap == tap }
    }

    /// Installed packages whose *effective* tap is this one — the receipt outranks the catalog,
    /// so a collided tap install still counts toward its true origin.
    func installedCount(fromTap tap: String) -> Int {
        installed.count { id, info in
            (info.tap ?? catalogIndex[id]?.tap) == tap
        }
    }

    /// Default-GitHub `user/repo` only: URLs and flags are unrepresentable, and the shape keeps
    /// brew's trust reference clean.
    nonisolated static func isValidTapName(_ name: String) -> Bool {
        // First characters alphanumeric: brew would read a leading dash as a flag.
        name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*/) != nil
    }

    func addTap(_ name: String) {
        guard Self.isValidTapName(name) else { return }
        enqueue(.tap(name: name.lowercased()), title: "Adding \(name)", targetID: nil)
    }

    func removeTap(_ name: String) {
        guard Self.isValidTapName(name) else { return }
        enqueue(.untap(name: name), title: "Removing \(name)", targetID: nil)
    }

    /// The one guarded trust write: the caller has shown the confirmation dialog by the time
    /// this runs. Post-op refresh re-reads the store, so badges and banners follow.
    func trustTap(_ name: String) {
        guard Self.isValidTapName(name) else { return }
        enqueue(.trustTap(name: name), title: "Trusting \(name)", targetID: nil)
    }

    /// The privilege-reducing direction needs no dialog: it is reversible from the tap page's
    /// banner, and brew strips the tap's per-item trust entries along with it.
    func untrustTap(_ name: String) {
        guard Self.isValidTapName(name) else { return }
        enqueue(.untrustTap(name: name), title: "Untrusting \(name)", targetID: nil)
    }

    /// A second update queued behind a pending one would just no-op for five seconds.
    private var updatePending: Bool {
        operations.contains { $0.command == .update && !$0.isFinished }
    }

    private func pump() {
        // Held while the inline freshness check runs: `brew update` takes a non-blocking
        // exclusive flock, so a concurrent queued mutation's own update would error, not wait.
        // The check's completion pumps again.
        guard runningTask == nil, !isCheckingForUpdates,
              let next = operations.first(where: { $0.state == .queued }) else { return }

        next.state = .running
        runningTask = Task { await self.execute(next) }
    }

    private func execute(_ operation: BrewOperation) async {
        let state: BrewOperation.State
        do {
            let code = try await client.run(operation.command) { line in
                operation.append(line)
            }
            state = code == 0 ? .succeeded : .failed
        } catch BrewError.cancelled {
            state = .cancelled
        } catch BrewError.notFound {
            operation.append("Error: Homebrew was not found.")
            state = .failed
        } catch {
            operation.append("Error: \(error.localizedDescription)")
            state = .failed
        }

        operation.state = state
        // Set in the same synchronous block as `state`, so no frame sees the gap between them.
        operation.awaitingRefresh = true
        if state == .failed, failureToPresent == nil {
            failureToPresent = operation
        }

        runningTask = nil
        // Success or failure, a mutation can have changed what is installed — and until that
        // refresh lands, the operation keeps holding its card: dropping busy on completion
        // alone showed the pre-mutation overlays for the second the probes take.
        Task {
            await self.refreshState()
            operation.awaitingRefresh = false
        }
        pump()
    }

    /// Cancel sends SIGINT — the path brew traps and cleans up after.
    func cancel(_ operation: BrewOperation) {
        switch operation.state {
        case .running:
            runningTask?.cancel()
        case .queued:
            operation.state = .cancelled
        default:
            break
        }
    }

    func remove(_ operation: BrewOperation) {
        guard operation.state == .queued else { return }
        operations.removeAll { $0.id == operation.id }
    }

    /// Safari's Downloads grammar: Clear drops what is done, keeps what is queued or running.
    /// An operation still awaiting its refresh stays too — removing it would drop the busy hold
    /// and resurrect the stale-answer blink for its card.
    func clearFinishedOperations() {
        operations.removeAll { $0.isFinished && !$0.awaitingRefresh }
    }

    /// The `.app` bundles this cask put on disk and that are still there. Resolved per call, not
    /// cached: an app dragged to the Trash should stop being offered.
    func launchableApps(for package: Package) -> [URL] {
        (installed[package.id]?.apps ?? []).compactMap(Receipts.appURL(named:))
    }

    /// Handed to LaunchServices, which starts the app as its own process — nothing is spawned as
    /// a child of Brewery, so quitting Brewery leaves it running.
    func openApp(at url: URL) {
        Task { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    /// The first of a font cask's files still in `~/Library/Fonts` — the Open target on the
    /// card and in the pane. Resolved per call like `launchableApps`, so a font deleted by
    /// hand stops being offered.
    func installedFontURL(for package: Package) -> URL? {
        guard package.isFont, installed[package.id] != nil else { return nil }
        return package.artifacts.first { $0.kind == .font }?
            .names.lazy.compactMap { FontPreview.fontURL(named: $0) }.first
    }

    /// A font file's default handler is Font Book; LaunchServices does the rest.
    func openFont(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    func latestOperation(for package: Package) -> BrewOperation? {
        operations.last { $0.targetID == package.id }
    }

    var isQueueActive: Bool { operations.contains { !$0.isFinished } }

    /// Whether the most recent finished operation failed. The popover auto-presents once and can be
    /// dismissed, after which nothing said a failure had happened — so the toolbar keeps a tell
    /// until something else finishes successfully.
    var lastOperationFailed: Bool {
        operations.last { $0.isFinished }?.state == .failed
    }

    var activeCount: Int { operations.filter { !$0.isFinished }.count }

    var isMutating: Bool {
        operations.contains { $0.state == .running && $0.command.isMutating }
    }

    /// Quit path: drop what has not started, then interrupt what has.
    func interruptRunning() {
        operations.removeAll { $0.state == .queued }
        runningTask?.cancel()
    }

    // MARK: - Menu commands

    func requestFind() {
        findRequests += 1
    }

    func requestAddTap() {
        selection = .taps
        addTapRequests += 1
    }
}
