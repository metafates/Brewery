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
    private(set) var catalogLoading = false
    var catalogFailed = false

    /// Overlays are keyed by `Package.ID` (`kind:shortname`). Persisted as a last-known
    /// snapshot (`StateSnapshot`) and restored at bootstrap, so launch shows the previous
    /// session's state for the second the probes take instead of a grid of Install buttons;
    /// the probes then correct it silently.
    var installed: [Package.ID: InstalledInfo] = [:]
    var outdated: [Package.ID: OutdatedInfo] = [:] {
        // Dock reporting lives in the model, not a view: the badge must keep counting
        // after the last window closes.
        didSet {
            NSApp.dockTile.badgeLabel = outdated.isEmpty ? nil : outdated.count.formatted(.number)
        }
    }

    /// "Who requires X", inverted from the receipt dependency lists and rebuilt on every refresh,
    /// in the same step as the installed overlay it is derived from.
    var dependents: [Package.ID: [Package.ID]] = [:]

    /// What `brew services list` reports, keyed by short formula name. Every installed
    /// formula that defines a service has an entry, whatever its state.
    var serviceStatuses: [String: ServiceStatus] = [:]

    /// The pin-ledger scan (`PinStore.scan`) — the outdated payload's `pinned` flag only
    /// covers outdated packages, so `isPinned` unions this with it.
    var pinned: Set<Package.ID> = []

    var operations: [BrewOperation] = []
    var brewMissing = false

    /// ⌘R does its work in the background and used to say nothing while it did. Drives the spinning
    /// toolbar glyph, so a refresh is visibly happening rather than apparently ignored.
    private(set) var isRefreshing = false

    /// True while the inline `brew update` of the freshness rule runs. Drives the Outdated
    /// page's "Checking for updates…" states; also holds `pump()`, so a mutation enqueued
    /// mid-check starts right after it (with fresh metadata) instead of colliding with brew's
    /// exclusive update flock.
    private(set) var isCheckingForUpdates = false

    /// In-flight `refreshState()` passes — the probe work no other flag names: the
    /// post-mutation reconcile and the background check's re-probe. A counter, not a Bool,
    /// because passes overlap (a ⌘R can overtake a post-mutation pass); bumped inside
    /// `refreshState()` itself so every caller counts.
    private var activeStateRefreshes = 0

    /// The app's one "state work is happening" signal: ⌘R, the inline metadata check, the
    /// catalog download, and any in-flight probe pass. Drives the spinning toolbar glyph and
    /// every empty slot's working capsule — and blocks nothing: content stays sharp and
    /// interactive while it is true. Composed, never set, so it cannot drift from the flags
    /// it reads. (`isCheckingForUpdates` stays the *narrow* flag: the inline `brew update`.)
    var isChecking: Bool {
        Self.checking(refreshing: isRefreshing, updatingMetadata: isCheckingForUpdates,
                      loadingCatalog: catalogLoading, stateRefreshes: activeStateRefreshes)
    }

    /// Pure so the composition is testable without a client (`shouldBackgroundCheck`'s rule).
    nonisolated static func checking(refreshing: Bool, updatingMetadata: Bool,
                                     loadingCatalog: Bool, stateRefreshes: Int) -> Bool {
        refreshing || updatingMetadata || loadingCatalog || stateRefreshes > 0
    }

    /// The newest API payload mtime, brew's "metadata last known good" (terminal updates
    /// count too). Re-stat'd on every refresh; feeds the "Last checked" caption and the
    /// staleness gate.
    private(set) var metadataCheckedAt: Date?

    /// Set once when an operation fails so the operations popover can auto-present; the view
    /// clears it after showing.
    var failureToPresent: BrewOperation?

    /// The current batch's outcome, for the one success knock when the queue drains in the
    /// background. Failure already bounces through `failureToPresent`; a mixed batch must
    /// bounce once, not twice.
    private var batchHadSuccessfulMutation = false
    private var batchHadFailure = false

    /// One search query per sidebar section, so queries never leak across tabs and each survives
    /// switching away and back. It lives here rather than in the view because switching sections
    /// tears the detail column down, taking any `@State` query with it.
    var queries: [SidebarSection: String] = [:]

    /// The current section's query — what `.searchable` binds directly. The dictionary stays
    /// the storage so queries never leak across tabs.
    var query: String {
        get { queries[selection ?? .discover] ?? "" }
        set { queries[selection ?? .discover] = newValue }
    }

    /// The sidebar's destination, and whether the operations popover is showing. Both are in the
    /// model rather than the view because the menu bar owns commands for them — View ▸ the five
    /// sections, View ▸ Show Operations — and a `Commands` builder can only reach app-level state.
    /// Persisted: the app reopens where it was left — HIG Launching, "restore the previous
    /// state when your app restarts so people can continue where they left off". Someone who
    /// lives in Outdated should not re-navigate there every launch.
    var selection: SidebarSection? = SidebarSection(
        rawValue: UserDefaults.standard.string(forKey: "sidebar.section") ?? "") ?? .discover {
        didSet {
            if let selection { UserDefaults.standard.set(selection.rawValue, forKey: "sidebar.section") }
            // Leaving Taps closes its drill-down; landing anywhere is a whole section.
            if selection != .taps { selectedTap = nil }
        }
    }

    /// The Taps section's in-column drill-down: nil shows the tap list, a name shows that tap's
    /// package grid. "homebrew/core"/"homebrew/cask" select the API-backed catalogs. Model
    /// state for `selection`'s own reason: menu commands need to read and steer it — the
    /// request-counter channel this replaces existed only because they couldn't.
    var selectedTap: String?
    /// The Add Tap popover, anchored to the tap list's + toolbar button.
    var showAddTap = false
    var showOperations = false
    /// Open by default: the first card click then describes into a pane that is already laid
    /// out, instead of reflowing the whole grid to make room (Mail's reading-pane grammar —
    /// present with a No Selection placeholder until something is chosen). Hidden-or-shown
    /// persists across launches: pane visibility is personalization (HIG macOS: let people
    /// configure windows to display the views they use most), so a closed pane stays closed.
    var showInspector = UserDefaults.standard.object(forKey: "inspector.shown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "inspector.shown") }
    }
    /// The package the pane is describing. In the model, not the view, for `selection`'s
    /// own reason: the menu bar's Uninstall command needs a target, and a `Commands` builder can
    /// only reach app-level state. Session state, never persisted — unlike the pane's
    /// visibility, *what* was being read is not personalization.
    var selectedPackage: Package?

    /// Bumped on every card selection, including of the already-shown package:
    /// assigning an equal `selectedPackage` re-renders nothing, so the pane listens to this
    /// counter (the ⌘F channel's shape) to pop its drill-down stack back to the root.
    private(set) var selectionRequests = 0

    /// The one selection funnel: card click and search's Return both land here.
    func select(_ package: Package) {
        selectedPackage = package
        showInspector = true
        selectionRequests += 1
    }

    /// Bumped by the ⌘F menu command. `ContentView` observes it and moves focus to the search
    /// field — the automatic ⌘F binding has historically been unreliable on macOS.
    private(set) var findRequests = 0

    /// ⌘[ lives in the menu bar with one owner: the content column's tap page wins when both
    /// stacks are deep (the committed rule — two view-level claims on one shortcut let SwiftUI
    /// pick arbitrarily); otherwise the pane's drill-down pops via the counter.
    private(set) var backRequests = 0
    /// The pane's drill depth, published so View ▸ Back can enable itself.
    var paneDepth = 0

    func requestBack() {
        if selectedTap != nil {
            selectedTap = nil
        } else {
            backRequests += 1
        }
    }

    let client = BrewClient()

    private var catalogFetchedAt: Date?
    private var didBootstrap = false
    /// When the last inline `brew update` was *started*, successful or not. brew only
    /// touches the payload mtime on success, so without this an offline machine would re-attempt
    /// (and time out) on every single ⌘R; with it, once per window.
    private var lastMetadataAttempt: Date?
    private var runningTask: Task<Void, Never>?
    private var backgroundCheckTask: Task<Void, Never>?
    /// When the last background pass ran — the timer's ticks and the wake trigger share it, so
    /// the interval is a cadence and not just the timer's period. Seeded at bootstrap, whose own
    /// freshness check *is* the launch pass; leaving it nil would make the first lid-open run a
    /// second one minutes later.
    private var lastBackgroundCheck: Date?
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

        // Shot-test seeding: the tap-trust and PATH findings vanished from this
        // machine once the login-shell overlay fixed the environment, so the structured
        // rendering is exercised through canned findings shaped verbatim like brew's
        // (diagnostic.rb pins the texts). Routed through `ingestCheckup` so the demo runs
        // the same readlink resolution as a real report.
        if ProcessInfo.processInfo.arguments.contains("-demo-checkup") {
            Task { await seedDemoCheckup() }
        }
    }

    private func seedDemoCheckup() async {
        let report = DoctorReport(tier: .number(1), findings: [
            .init(
                text: """
                /usr/bin occurs before /opt/homebrew/bin in your PATH.
                This means that system-provided programs will be used instead of those
                provided by Homebrew.

                The following tools exist at both paths:
                  gem
                  git
                  irb
                  jq
                  ruby
                """,
                tier: nil, affects: nil, links: nil,
                remediation: .init(
                    commands: ["fish_add_path /opt/homebrew/bin"],
                    text: """
                    Consider setting your PATH so that
                    /opt/homebrew/bin occurs before /usr/bin. Here is a one-liner:
                      fish_add_path /opt/homebrew/bin
                    """)),
            .init(
                text: """
                The following taps are not trusted:
                  charmbracelet/tap
                  oven-sh/bun

                Homebrew is currently ignoring formulae, casks and commands from these taps because tap trust is required.
                """,
                tier: nil, affects: nil, links: ["https://docs.brew.sh/Tap-Trust"],
                remediation: .init(
                    commands: nil,
                    text: """
                    Prefer trusting only the specific formulae, casks or commands you need.
                    Trust installed formulae from these taps with:
                      brew trust --formula charmbracelet/tap/crush charmbracelet/tap/gum
                      brew trust --formula oven-sh/bun/bun
                    Trust other specific casks and commands with:
                      brew trust --cask <user>/<tap>/<cask>
                      brew trust --command <user>/<tap>/<command>
                    Whole-tap trust is broader and includes all current and future formulae,
                    casks and commands from the listed taps. Trust whole taps with:
                      brew trust charmbracelet/tap oven-sh/bun
                    Untap them with:
                      brew untap charmbracelet/tap oven-sh/bun
                    For more information, see:
                      https://docs.brew.sh/Tap-Trust
                    """)),
            .init(
                text: """
                You have unlinked kegs in your Cellar.
                Leaving kegs unlinked can lead to build-trouble and cause formulae that depend on
                those kegs to fail to run properly once built.
                """,
                tier: nil, affects: nil, links: nil,
                remediation: .init(commands: ["brew link deno", "brew link parallel"],
                                   text: "Run `brew link` on these:\n  deno\n  parallel")),
        ])
        await ingestCheckup(report)
        checkupRanAt = .now
    }

    // MARK: - Loading

    /// Cache first so the grid is populated immediately, then the installed/outdated probes and
    /// (only if the catalog is stale or absent) the download run concurrently.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        // Before the first await: bootstrap may be cancelled with its caller, and the
        // periodic check must outlive whatever started it. The launch pass below is this
        // cadence's first tick, so the clock starts here rather than at the first wake.
        lastBackgroundCheck = .now
        startBackgroundChecks()

        // Last session's overlays before anything else, so the first frame shows
        // last-known install state instead of Install buttons; the probes below correct it.
        if let snapshot = StateSnapshot.load() {
            installed = snapshot.installed
            outdated = snapshot.outdated
            serviceStatuses = snapshot.serviceStatuses
            pinned = snapshot.pinned ?? []
            dependents = Receipts.invertDependents(snapshot.installed)
        }

        let cache = await CatalogStore.loadCache()
        if let cache {
            tapInstalls90d = cache.tapInstalls90d ?? [:]
            await setCoreCatalog(cache.packages)
            catalogFetchedAt = cache.fetchedAt
        }

        // The overlay must land before the first probes and tap scan: it was pre-warmed
        // in the client's init, so this await typically resolves instantly; worst case (a
        // broken dotfile) it's the capture timeout, paid once.
        _ = await client.shellEnvironment()

        async let state: Void = refreshState()
        if cache.map({ CatalogStore.isStale($0.fetchedAt) }) ?? true {
            await loadCatalog()
        }
        await state

        // Probes first (cached-metadata answers on screen in a second), then the freshness
        // rule corrects them: brew's own outdated computation runs against a cache our standing
        // HOMEBREW_NO_AUTO_UPDATE freezes, so a stale launch re-probes after one `brew update`.
        if await checkForUpdatesIfStale() {
            // The claim must wait for the answer: the flag stays up through the re-probe, or an
            // empty Outdated page says "Everything is up to date" for the second it takes the
            // fresh read to land — the exact lie the freshness rule exists to kill. No suspension between the
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

        // Unlike bootstrap, the check runs *before* the probes: one landing beats showing
        // stale answers mid-refresh only to swap them seconds later.
        // Forced: ⌘R is an explicit request, and explicit requests are never coalesced.
        _ = await checkForUpdatesIfStale(force: true)

        async let state: Void = refreshState()
        if catalogFetchedAt.map(CatalogStore.isStale) ?? true {
            await loadCatalog()
        }
        await state
    }

    /// The freshness rule: brew's metadata must be no older than brew's own API window
    /// (450 s) before `outdated` is worth asking. An explicit `brew update` is not gated by
    /// `HOMEBREW_NO_AUTO_UPDATE` (only the auto-update path checks it), so it refreshes the API
    /// cache and tap clones even with our env set. Failure is silent by design — the probes fall
    /// back to the cached answer. Returns whether an update ran.
    /// ⌘R passes `force`: the window is brew's *auto*-update coalescing rule and an
    /// explicit `brew update` always runs — pressing Refresh at "Last checked 7 minutes ago"
    /// used to visibly do nothing. The queue and re-entrancy guards stay; only the clocks yield.
    private func checkForUpdatesIfStale(force: Bool = false) async -> Bool {
        metadataCheckedAt = client.metadataDate()
        guard client.isAvailable, !isCheckingForUpdates, !isQueueActive,
              force || metadataIsStale else {
            return false
        }
        if !force, let attempt = lastMetadataAttempt,
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

    // MARK: - Background check

    /// The menu bar presence's clock: with the window closed the app still answers for
    /// updates, so every 6 hours — and on wake — the gentle bootstrap-shaped pass runs:
    /// the staleness-gated metadata check plus a re-probe. Never the forced `refresh()`:
    /// force is the explicit-request semantic, and a cadence that forced `brew update` past
    /// the staleness gate would spend network every 6 hours for no one. The pass is not
    /// invisible — any state work in flight spins the toolbar glyph (`isChecking`), which is
    /// the whole of the feedback a background pass earns.
    /// `BackgroundCheckTests` pins the interval — a dev-time short cadence must not ship.
    nonisolated static let backgroundCheckInterval: Duration = .seconds(6 * 60 * 60)

    /// Pure so the gate is testable without a client: a tick yields to an active queue or a
    /// user-initiated refresh; staleness and attempt-backoff live in `checkForUpdatesIfStale`.
    ///
    /// `last` is what makes the interval the *cadence* rather than just the timer's period. The
    /// wake trigger shares this gate: brew's own staleness window is 450 s, so a lid-open eight
    /// minutes later used to spend a `brew update` plus a full re-probe — every lid-open, all
    /// day, on a laptop. The documented promise is every 6 hours, so wake advances that clock
    /// instead of bypassing it. A `last` in the future (clock moved back) reads as due, not as
    /// blocked forever.
    nonisolated static func shouldBackgroundCheck(
        queueActive: Bool, refreshing: Bool, last: Date?, now: Date
    ) -> Bool {
        guard !queueActive, !refreshing else { return false }
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= TimeInterval(backgroundCheckInterval.components.seconds)
    }

    private func startBackgroundChecks() {
        guard backgroundCheckTask == nil else { return }
        backgroundCheckTask = Task { [weak self] in
            // ContinuousClock runs through system sleep, so a long sleep fires this tick
            // immediately on wake — same guards as the wake trigger, harmless double.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundCheckInterval)
                await self?.backgroundCheck()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.backgroundCheck() }
        }
    }

    private func backgroundCheck() async {
        guard Self.shouldBackgroundCheck(queueActive: isQueueActive, refreshing: isRefreshing,
                                         last: lastBackgroundCheck, now: .now) else {
            return
        }
        // Stamped before the work, not after: the pass takes seconds, and a second wake
        // landing mid-pass must see the clock already advanced.
        lastBackgroundCheck = .now
        _ = await checkForUpdatesIfStale()
        await refreshState()
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
    /// the alphabetically-first tap win tap-vs-tap — the accepted-collision rule, extended.
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
        // Counted here, not at call sites, so every pass raises `isChecking` — bootstrap,
        // ⌘R, the background check, and the flagless post-mutation reconcile alike.
        activeStateRefreshes += 1
        defer { activeStateRefreshes -= 1 }

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
            pinned = []
            // This branch publishes too (empty overlays), so it releases holds the same way.
            releaseRefreshHolds(before: generation)
            // Persisted too: brew gone is a state, not an error — the next launch must not
            // resurrect a graveyard of Installed badges.
            persistStateSnapshot()
            return
        }

        // Four independent probes, structured: `async let` runs them concurrently and each
        // read stays independently optional (the pin scan cannot fail — a missing ledger is
        // an empty set).
        async let installedFetch = client.listInstalled()
        async let outdatedFetch = client.outdated()
        async let servicesFetch = client.servicesList()
        async let pinnedScan = PinStore.scan(prefix: client.prefix)

        let installedResult = await installedFetch
        let outdatedResult = try? await outdatedFetch
        let servicesResult = try? await servicesFetch
        let pinnedResult = await pinnedScan

        let merged = Self.mergeInstalled(formulae: installedResult.formulae,
                                         casks: installedResult.casks,
                                         previous: installed)
        let folded: [Package.ID: InstalledInfo]?
        if let merged {
            folded = await withReceipts(merged)
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
                                       installs90d: tapInstalls90d,
                                       environment: client.effectiveEnvironment)
        } else {
            scan = nil
        }

        // A refresh started later holds the fresher answer; the sweep is slow enough that a ⌘R or a
        // post-mutation refresh can overtake this one, and a late write would mix the two.
        guard generation == refreshGeneration else { return }
        releaseRefreshHolds(before: generation)
        if let folded {
            installed = folded
            dependents = Receipts.invertDependents(folded)
        }
        if let outdatedResult { outdated = outdatedResult }
        if let servicesResult { serviceStatuses = servicesResult }
        pinned = pinnedResult
        // Recompose only on a real change — scans are usually identical, and an unchanged catalog
        // must not invalidate the view layer's keys.
        if let scan, scan != tapScan {
            tapScan = scan
            composeCatalog()
        }

        // Persist what was just published; the next launch's first frame reads it back.
        persistStateSnapshot()
    }

    /// Per-kind degrade for the installed probe: a fresh side replaces its own entries
    /// wholesale, a failed side keeps its previous ones — the two lists are independent brew
    /// commands, and one crashing must not freeze the other's state (the harlequin bug: a
    /// brew master regression in `list --cask` kept every uninstalled formula "Installed").
    /// Both failed reads as offline: nil, and the caller keeps the whole overlay untouched.
    /// Pure so `InstalledMergeTests` can pin the truth table.
    nonisolated static func mergeInstalled(
        formulae: [Package.ID: InstalledInfo]?,
        casks: [Package.ID: InstalledInfo]?,
        previous: [Package.ID: InstalledInfo]
    ) -> [Package.ID: InstalledInfo]? {
        guard formulae != nil || casks != nil else { return nil }
        func previousEntries(_ kind: PackageKind) -> [Package.ID: InstalledInfo] {
            previous.filter { Package.components(of: $0.key)?.0 == kind }
        }
        var result = formulae ?? previousEntries(.formula)
        result.merge(casks ?? previousEntries(.cask)) { _, cask in cask }
        return result
    }

    /// Fire-and-forget by design: the write is off the refresh critical path, and a failed one
    /// only costs the next launch its head start.
    private func persistStateSnapshot() {
        let snapshot = StateSnapshot(installed: installed, outdated: outdated,
                                     serviceStatuses: serviceStatuses, pinned: pinned)
        Task { await snapshot.save() }
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
            result[id]?.builtFromSource = receipt.builtFromSource
            result[id]?.installedAt = receipt.installedAt
            result[id]?.hasZap = receipt.hasZap
        }
        return result
    }

    // MARK: - Disk sizes

    /// Measured bytes per installed package, the Size sort's key. Filled by `measureSizes`
    /// through the same session cache the pane's Size row uses, so the two share every walk.
    private(set) var diskSizes: [Package.ID: Int64] = [:]
    /// Bumped once per sweep that changed something — the browse listing's re-sort signal.
    private(set) var sizesGeneration = 0
    /// True while a sweep runs, so the listing can say "Measuring sizes…" instead of silently
    /// showing an order that is about to change.
    private(set) var isMeasuringSizes = false

    /// Where an installed package's bytes live — the one home for the answer, shared by the
    /// pane's Size row and the size sort's sweep. A formula is its whole `Cellar/<name>` (every
    /// keg on disk is what the machine is paying); a cask is its Caskroom slot plus the moved
    /// artifacts (apps via the receipt, font files by artifact name).
    /// The old kegs of a multi-version formula: every `Cellar/<name>/<version>` but the
    /// current one. Keys are namespaced `oldkeg:` because the pane's Size row caches the *whole*
    /// rack under the same id|version pair — one cache, two meanings would poison each other.
    nonisolated static func oldKegRoots(prefix: URL, name: String, versions: [String])
        -> [(key: String, root: URL)] {
        versions.dropLast().map { version in
            ("oldkeg:formula:\(name)|\(version)",
             prefix.appending(path: "Cellar", directoryHint: .isDirectory)
                 .appending(path: name, directoryHint: .isDirectory)
                 .appending(path: version, directoryHint: .isDirectory))
        }
    }

    func sizeRoots(for package: Package) -> [URL] {
        guard let prefix = client.prefix else { return [] }
        switch package.kind {
        case .formula:
            return [prefix.appending(path: "Cellar", directoryHint: .isDirectory)
                .appending(path: package.name, directoryHint: .isDirectory)]
        case .cask:
            var roots = [prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
                .appending(path: package.name, directoryHint: .isDirectory)]
            roots += launchableApps(for: package)
            let fontNames = package.artifacts.first { $0.kind == .font }?.names ?? []
            roots += fontNames.compactMap { FontPreview.fontURL(named: $0) }
            return roots
        }
    }

    /// Measures every installed package, six keg walks at a time — each walk enumerates tens of
    /// thousands of files, so unbounded width is fd pressure for nothing. Publishes **once** at
    /// the end: 350 per-keg assignments would rebuild the sorted listing 350 times. A warm pass
    /// (session cache) finishes in milliseconds and publishes nothing new.
    func measureSizes() async {
        guard !isMeasuringSizes else { return }
        isMeasuringSizes = true
        defer { isMeasuringSizes = false }

        let targets: [(Package.ID, String, [URL])] = installed.compactMap { id, info in
            guard let package = package(for: id) else { return nil }
            let key = DiskUsage.cacheKey(for: id, version: info.versions.last)
            return (id, key, sizeRoots(for: package))
        }

        var result: [Package.ID: Int64] = [:]
        var iterator = targets.makeIterator()
        await withTaskGroup(of: (Package.ID, Int64?).self) { group in
            for _ in 0..<6 {
                guard let (id, key, roots) = iterator.next(),
                      group.addTaskUnlessCancelled(operation: {
                          (id, await DiskUsage.measuredBytes(key: key, roots: roots))
                      }) else { break }
            }
            while let (id, bytes) = await group.next() {
                if let bytes { result[id] = bytes }
                guard let (nextID, key, roots) = iterator.next() else { continue }
                guard group.addTaskUnlessCancelled(operation: {
                    (nextID, await DiskUsage.measuredBytes(key: key, roots: roots))
                }) else { break }
            }
        }

        // A cancelled sweep (the sort switched away, the section closed) must not publish a
        // partial map — that would wipe already-measured sizes and bump the generation for a
        // listing rebuild built on the wipe.
        guard !Task.isCancelled else { return }
        if result != diskSizes {
            diskSizes = result
            sizesGeneration &+= 1
        }
    }

    // MARK: - Derived state

    /// The Attention bar's headline: one integer, counted off the catalog directly. The
    /// scope-listing path builds merged()'s arrays and sets just to be counted, and the
    /// synthesized tap-only entries it adds never carry needsAttention.
    var attentionCount: Int {
        catalog.count { installed[$0.id] != nil && $0.needsAttention }
    }

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

    /// Releases the busy holds of operations that finished before the given refresh run.
    /// Called from a publish block only: the overlays on screen now postdate those operations.
    func releaseRefreshHolds(before generation: Int) {
        for operation in operations
        where operation.awaitingRefresh && operation.awaitingRefreshSince < generation {
            operation.awaitingRefresh = false
        }
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
               outdated[package.id] != nil, !isPinned(package) {
                return true
            }
        }
        return false
    }

    /// Catalog entries that are installed, plus synthesized ones for anything installed from a tap
    /// the catalog does not cover.
    private var installedPackages: [Package] {
        merged(catalog.filter { installed[$0.id] != nil },
               with: installed.mapValues { $0.versions })
    }

    /// The orphan report: what `brew autoremove` would remove. Cask receipts carry no
    /// runtime dependencies, so each installed cask's `depends_on` formulae come from the
    /// catalog — that is how brew itself protects them (`utils/autoremove.rb` reads the cask
    /// DSL, not tabs). Recomputed per access; ~350 kegs and a few rounds are well under a
    /// millisecond.
    var orphanIDs: Set<Package.ID> {
        Receipts.orphans(in: installed, caskDependencies: installedCaskDependencies)
    }

    /// How many formulae carry more than one keg. The Storage listing's invalidation
    /// signal: cleanup removes kegs without changing the *package* count the browse keys
    /// otherwise watch, so this is the number that has to sit in the keys.
    var multiKegCount: Int {
        installed.count { $0.key.hasPrefix("formula:") && $0.value.versions.count > 1 }
    }

    /// Each installed cask's catalog `depends_on` formulae — cask receipts carry no runtime
    /// deps, so the claim comes from the catalog, which is how brew itself protects them.
    /// Shared by the orphan fixpoint and the uninstall block list.
    private var installedCaskDependencies: [Package.ID: [String]] {
        var result: [Package.ID: [String]] = [:]
        for id in installed.keys where id.hasPrefix("cask:") {
            if let deps = package(for: id)?.caskDependencies, !deps.isEmpty {
                result[id] = deps
            }
        }
        return result
    }

    /// The Installed section under the scope picker. `.all` is the full list; `.onRequest` drops the
    /// kegs that are only on disk because something else needed them; `.orphans` keeps only
    /// what `brew autoremove` would remove; `.attention` what Homebrew has retired.
    func installedPackages(scope: InstalledScope) -> [Package] {
        switch scope {
        case .all:
            return installedPackages
        case .onRequest:
            return installedPackages.filter { installed[$0.id]?.onRequest ?? true }
        case .orphans:
            // Resolved once, not per element — the fixpoint is cheap but not free.
            let orphans = orphanIDs
            return installedPackages.filter { orphans.contains($0.id) }
        case .attention:
            return installedPackages.filter(\.needsAttention)
        case .storage:
            // Formulae carrying more than one keg: the set `brew cleanup` acts on.
            // Formula-only because no-args cleanup iterates Formula.installed (cleanup.rb:399);
            // old Caskroom versions are an upgrade artifact, not a cleanup target.
            return installedPackages.filter {
                $0.kind == .formula && (installed[$0.id]?.versions.count ?? 0) > 1
            }
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
        return result.sorted(by: Package.displayOrder)
    }

    private static func synthesize(id: Package.ID, versions: [String]) -> Package? {
        guard let (kind, name) = Package.components(of: id) else { return nil }
        return Package(kind: kind,
                       name: name,
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
             let .tap(name), let .untap(name), let .trustTap(name), let .untrustTap(name),
             let .uninstall(name, _), let .zap(name), let .link(name),
             let .pin(name, _), let .unpin(name, _):
            guard !name.isEmpty, !name.hasPrefix("-") else { return }
        default:
            // Argument-less commands only. A new case that carries a name MUST join the list
            // above — this default would otherwise exempt it from the guard silently.
            break
        }

        // Auto-update is disabled on every invocation, so a package mutation must bring
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

    /// The package whose Install awaits the trust-consent dialog; nil = no dialog.
    var pendingInstall: Package?

    var trustConsentPresented: Bool {
        get { pendingInstall != nil }
        set { if !newValue { pendingInstall = nil } }
    }

    /// Installing a qualified tap item makes brew trust that item's recipe as a silent side
    /// effect (`cmd/install.rb` runs `Trust.trust_fully_qualified_items!` before the gate;
    /// the gate itself never prompts — `trust.rb` just refuses). Consent is asked only when
    /// that grant would be new. The scan guard mirrors `qualifiedName`: a tap outside the
    /// scan installs unqualified and grants nothing.
    func installNeedsTrustConsent(_ package: Package) -> Bool {
        guard let tap = effectiveTap(for: package), tapScan.taps.contains(tap) else { return false }
        return trustState.needsConsent(tap: tap, name: package.name)
    }

    /// Every Install surface funnels through here — pane, card, context menu — so the
    /// consent dialog cannot be bypassed by installing from a different corner of the app.
    func install(_ package: Package) {
        guard !installNeedsTrustConsent(package) else {
            pendingInstall = package
            return
        }
        confirmedInstall(package)
    }

    /// The dialog's two affirmative paths. FIFO queue: the trust grant, when asked for,
    /// lands before the install starts.
    func confirmedInstall(_ package: Package, trustingTap: Bool = false) {
        if trustingTap, let tap = effectiveTap(for: package) {
            trustTap(tap)
        }
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

    /// Guarded in the funnel, not per-caller: four surfaces reach this (toolbar, ⇧⌘U, the
    /// menu bar extra, the Dock menu) and only the toolbar consulted `upgradeAllPending`. The
    /// other three gate on `outdated.isEmpty`, which cannot change while the upgrade runs, so
    /// a second press queued a whole redundant `brew upgrade`; the Dock item has no `.disabled`
    /// hook to patch at all. `runCheckup` sets the precedent.
    func upgradeAll() {
        guard !upgradeAllPending else { return }
        enqueue(.upgradeAll, title: "Updating all packages", targetID: nil)
    }

    /// The orphan report's action. The caller has shown the confirmation dialog by the
    /// time this runs (the trust-write rule); brew removes exactly the set the report showed.
    func autoremove() {
        enqueue(.autoremove, title: "Removing orphaned dependencies", targetID: nil)
    }

    /// An autoremove already on the queue makes a second press pure duplication.
    var autoremovePending: Bool {
        operations.contains { $0.command == .autoremove && !$0.isFinished }
    }

    /// The Storage report's action. The caller has shown the confirmation dialog (the
    /// trust-write rule). Files only: the standing HOMEBREW_NO_AUTOREMOVE=1 gates the package
    /// removal plain `brew cleanup` would otherwise run (cleanup.rb:412), and brew itself keeps
    /// linked, pinned and keepme kegs.
    func cleanUp() {
        enqueue(.cleanup, title: "Cleaning up", targetID: nil)
    }

    var cleanupPending: Bool {
        operations.contains { $0.command == .cleanup && !$0.isFinished }
    }

    /// How many finished cleanups this session — the Storage bar's re-measure signal.
    var finishedCleanupCount: Int {
        operations.count { $0.command == .cleanup && $0.isFinished && !$0.awaitingRefresh }
    }

    // MARK: - Checkup

    enum CheckupOutcome: Equatable {
        case report(DoctorReport)
        /// brew produced output the parser couldn't read (the hidden --json flag changed?) —
        /// the raw text is shown rather than swallowed.
        case unreadable(raw: String)
        case failed
    }

    /// Session-only, deliberately never snapshotted: a checkup describes this boot of the
    /// machine, and a stale verdict restored at launch would be a lie with a green checkmark.
    private(set) var checkupOutcome: CheckupOutcome?

    /// Whether the Checkup page is showing content worth keeping on screen while doctor
    /// re-runs — findings or raw output. The claim states (intro, clean, failed) are not:
    /// a wait may only occupy space that has nothing to show, so those are replaced by the
    /// capsule while content pages keep their findings and narrate in the header caption.
    var checkupHasContent: Bool {
        switch checkupOutcome {
        case .report(let report): !report.findings.isEmpty
        case .unreadable: true
        case .failed, nil: false
        }
    }
    private(set) var checkupRanAt: Date?
    private(set) var isRunningCheckup = false

    /// The PATH finding's shadowed tools, resolved to the packages that provide them.
    struct ShadowedPackage: Equatable, Identifiable {
        let package: Package
        let tools: [String]
        var id: Package.ID { package.id }
    }
    private(set) var checkupShadowed: [ShadowedPackage] = []
    private(set) var checkupShadowedUnresolved: [String] = []

    /// Runs `brew doctor --json` inline — a read, never queued (`enqueue` would refuse it
    /// anyway: reads aren't mutating). Exit 1 means findings exist, not failure (doctor sets
    /// failed on the first finding), so success is judged by parse, not exit code. stderr is
    /// split off (`onErrorLine`) so the JSON can't interleave with stray warnings.
    func runCheckup() async {
        guard !isRunningCheckup, !brewMissing else { return }
        isRunningCheckup = true
        defer { isRunningCheckup = false }

        let stdout = CheckupBuffer()
        let stderr = CheckupBuffer()
        do {
            let code = try await client.run(.doctor) { stdout.lines.append($0) }
                onErrorLine: { stderr.lines.append($0) }
            let text = stdout.lines.joined(separator: "\n")
            if code == 0 || code == 1, let report = DoctorReport.parse(text) {
                await ingestCheckup(report)
            } else if code == 0 || code == 1 {
                let raw = text.isEmpty ? stderr.lines.joined(separator: "\n") : text
                checkupShadowed = []
                checkupShadowedUnresolved = []
                checkupOutcome = .unreadable(raw: raw)
            } else {
                checkupShadowed = []
                checkupShadowedUnresolved = []
                checkupOutcome = .failed
            }
        } catch {
            checkupShadowed = []
            checkupShadowedUnresolved = []
            checkupOutcome = .failed
        }
        checkupRanAt = .now
    }

    /// Publishes a parsed report together with its precomputed shadow rows, in one
    /// step: the view must never see the report without them. Resolution is readlink-primary
    /// (`<prefix>/bin/<tool>` names its Cellar/Caskroom provider exactly — tap formulae
    /// included, `gem` → whatever is actually linked), with the executables index as the
    /// fallback for the odd plain-file entry, installed packages only.
    private func ingestCheckup(_ report: DoctorReport) async {
        var shadowed: [ShadowedPackage] = []
        var unresolved: [String] = []
        if let finding = report.findings.first(where: { FindingFormat.classify($0.text) == .pathShadowing }),
           let tools = CaveatFormat.blocks(of: finding.text).lazy.compactMap({ block -> [String]? in
               guard case .code(let code) = block else { return nil }
               return FindingFormat.toolList(inCode: code)
           }).first,
           let prefix = client.prefix {
            let destinations = await ShadowResolver.readLinks(
                tools: tools, binDirectory: prefix.appending(path: "bin"))
            let (groups, leftovers) = ShadowResolver.grouped(tools: tools) { tool in
                if let destination = destinations[tool],
                   let provider = ShadowResolver.provider(ofLinkDestination: destination) {
                    return Package.packageID(kind: provider.kind, name: provider.name)
                }
                return commandIndex[tool]?.first { installed[$0] != nil }
            }
            shadowed = groups.compactMap { group in
                package(for: group.id).map { ShadowedPackage(package: $0, tools: group.tools) }
            }
            unresolved = leftovers
                + groups.filter { package(for: $0.id) == nil }.flatMap(\.tools)
        }
        checkupShadowed = shadowed
        checkupShadowedUnresolved = unresolved
        checkupOutcome = .report(report)
    }

    /// The one doctor remediation the app runs itself. No dialog: link is non-destructive
    /// and reversible — the service-toggle rule, not the removal rule. The targetID keeps the
    /// one busy grammar (card and pane spin while it runs).
    func link(_ name: String) {
        enqueue(.link(name: name), title: "Linking \(name)",
                targetID: Package.packageID(kind: .formula, name: BrewClient.shortName(name)))
    }

    /// The last link operation for a formula — the Link button's three states read from it.
    func linkOperation(for name: String) -> BrewOperation? {
        operations.last { $0.command == .link(name: name) }
    }

    /// A finding's `affects` names resolved against the catalog — the caveat-mention rule:
    /// short name (doctor emits full names for tap items), formula first then cask, unresolved
    /// names dropped, order preserved, deduped.
    func resolvedAffected(_ names: [String]) -> [Package] {
        var seen: Set<Package.ID> = []
        return names.compactMap { name -> Package? in
            let short = BrewClient.shortName(name)
            let candidates = [Package.packageID(kind: .formula, name: short),
                              Package.packageID(kind: .cask, name: short)]
            guard let found = candidates.lazy.compactMap(package(for:)).first,
                  seen.insert(found.id).inserted else { return nil }
            return found
        }
    }

    /// Same rule for Update All — it lived in the view, spelled longhand.
    var upgradeAllPending: Bool {
        operations.contains { $0.command == .upgradeAll && !$0.isFinished }
    }

    // MARK: - Uninstall

    /// The package whose Uninstall awaits the confirmation dialog; nil = no dialog.
    var pendingUninstall: Package?

    var uninstallConfirmationPresented: Bool {
        get { pendingUninstall != nil }
        set { if !newValue { pendingUninstall = nil } }
    }

    /// pendingUninstall's grammar for taps: every Remove Tap… surface — list row, page
    /// header, menu bar — funnels here, and the one dialog runs before anything enqueues.
    var pendingTapRemoval: TapInfo?

    var tapRemovalPresented: Bool {
        get { pendingTapRemoval != nil }
        set { if !newValue { pendingTapRemoval = nil } }
    }

    /// App-level like the removal funnels: the Homebrew menu must open the same dialogs the
    /// content buttons do, from any section — a dialog can only present from a mounted view,
    /// so both live on ContentView's root.
    var confirmingCleanup = false
    var confirmingAutoremove = false

    /// Every Uninstall surface funnels through here — pane button, card context menu, menu bar —
    /// and it only sets the pending package: the confirmation dialog runs before anything
    /// enqueues (the trust-write rule). Pinned packages never pass — brew's pinned refusal
    /// exits 0 having removed nothing (`uninstall.rb:46-48`), and a lying success in the
    /// operations popover is worse than a disabled button.
    func uninstall(_ package: Package) {
        guard installed[package.id] != nil || outdated[package.id] != nil,
              !isPinned(package) else { return }
        pendingUninstall = package
    }

    /// The dialog's affirmative paths. `zap` holds only for a cask whose receipt records a zap
    /// stanza — the one case where `--zap` does more than plain uninstall.
    func confirmedUninstall(_ package: Package, zap: Bool = false) {
        let command = AppModel.uninstallCommand(name: qualifiedName(for: package),
                                                kind: package.kind,
                                                zap: zap,
                                                hasZap: installed[package.id]?.hasZap == true)
        enqueue(command, title: "Uninstalling \(package.title)", targetID: package.id)
    }

    /// Pure core of the zap choice, `blockingDependentIDs`'s shape: testable without enqueuing.
    nonisolated static func uninstallCommand(name: String, kind: PackageKind,
                                             zap: Bool, hasZap: Bool) -> BrewCommand {
        if zap, kind == .cask, hasZap {
            .zap(name: name)
        } else {
            .uninstall(name: name, cask: kind == .cask)
        }
    }

    /// Who would make brew refuse this uninstall: formulae listing it as a runtime dependency
    /// (the receipts' inverted map) plus installed casks whose catalog `depends_on` claims it —
    /// brew counts cask dependents too (`installed_dependents.rb:45`), but cask receipts carry
    /// no runtime deps, so the claim comes from the catalog like the orphan fixpoint's does.
    /// Display titles, sorted; non-empty means the dialog omits its destructive buttons.
    func blockingDependents(for package: Package) -> [String] {
        AppModel.blockingDependentIDs(of: package,
                                      dependents: dependents,
                                      caskDependencies: installedCaskDependencies)
            .map { self.package(for: $0)?.title ?? (Package.components(of: $0)?.name ?? $0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Pure core of the block list, `Receipts.orphans`'s shape: testable without a catalog.
    nonisolated static func blockingDependentIDs(of package: Package,
                                                 dependents: [Package.ID: [Package.ID]],
                                                 caskDependencies: [Package.ID: [String]]) -> Set<Package.ID> {
        guard package.kind == .formula else { return [] }  // the catalog decodes no cask→cask deps
        var ids = Set(dependents[package.id] ?? [])
        for (id, claims) in caskDependencies where claims.contains(package.name) {
            ids.insert(id)
        }
        return ids
    }

    /// The dialog's sample of the block list — a sample is only a summary if it stays short
    /// (the license row's law): four or fewer list in full, more collapse to three and a count.
    /// The full list stays one click away in the pane's Required By section.
    nonisolated static func dependentsSummary(_ names: [String]) -> String {
        guard names.count > 4 else { return names.formatted(.list(type: .and)) }
        return names.prefix(3).joined(separator: ", ") + ", and \(names.count - 3) more"
    }

    /// Read-only pin state, hoisted from the pane so the pane, the card's context
    /// menu and the menu bar all read one rule.
    /// The union of the pin-ledger scan and the outdated payload's flag: the scan covers
    /// pins on current packages, the flag bridges the gap between a pin landing and the
    /// next scan publishing.
    func isPinned(_ package: Package) -> Bool {
        pinned.contains(package.id) || outdated[package.id]?.pinned == true
    }

    /// The menu bar command's target: the selected package, if uninstalling it would work.
    var uninstallableSelection: Package? {
        guard let package = selectedPackage,
              installed[package.id] != nil || outdated[package.id] != nil,
              !isPinned(package) else { return nil }
        return package
    }

    /// Pin and unpin, one toggle: no dialog — non-destructive and mutually inverse, the
    /// service-toggle rule. Only something on disk can be pinned (pinning a not-installed
    /// name is brew's one pin failure, exit 1), and never mid-operation.
    func togglePin(_ package: Package) {
        guard installed[package.id] != nil || outdated[package.id] != nil,
              status(for: package) != .busy else { return }
        let command: BrewCommand = isPinned(package)
            ? .unpin(name: qualifiedName(for: package), cask: package.kind == .cask)
            : .pin(name: qualifiedName(for: package), cask: package.kind == .cask)
        enqueue(command,
                title: "\(isPinned(package) ? "Unpinning" : "Pinning") \(package.title)",
                targetID: package.id)
    }

    /// The menu bar's Pin/Unpin target — `uninstallableSelection`'s shape minus the pin
    /// check, since the command works both ways.
    var pinTargetSelection: Package? {
        guard let package = selectedPackage,
              installed[package.id] != nil || outdated[package.id] != nil,
              status(for: package) != .busy else { return nil }
        return package
    }

    /// One string for the card's and the pane's disabled Update — they must not drift.
    nonisolated static func pinnedUpdateHelp(_ title: String) -> String {
        "\(title) is pinned, so updates skip it. Unpin it to update."
    }

    // MARK: - Services

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

    // MARK: - Taps

    /// The Taps tab's rows, straight from the scan; the trust snapshot rides along.
    var tapInfos: [TapInfo] { tapScan.infos }
    var trustState: TrustState { tapScan.trust }

    /// A tap page's contents come from the scan, not the composed catalog: a tap entry that lost
    /// the core-vs-tap dedupe (bun was upstreamed into core) still belongs on *its tap's* page.
    func tapPackages(for tap: String) -> [Package] {
        tapScan.packages.filter { $0.tap == tap }
    }

    /// What a tap provides, core catalogs included: the one membership rule the Taps grid
    /// and the pane's tap page both read. Unsorted — each surface orders for its own audience.
    func packages(inTap tap: String) -> [Package] {
        switch tap {
        case "homebrew/core": catalog.filter { $0.kind == .formula && $0.tap == nil }
        case "homebrew/cask": catalog.filter { $0.kind == .cask && $0.tap == nil }
        default: tapPackages(for: tap)
        }
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
        // A page drilled into the tap being removed has nothing left to show.
        if selectedTap == name { selectedTap = nil }
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
        operation.awaitingRefreshSince = refreshGeneration
        if state == .failed, failureToPresent == nil {
            failureToPresent = operation
            // An install runs for minutes and people go elsewhere while it does. A popover
            // opening behind another app is not feedback; one Dock bounce is. Model-side,
            // beside the flag it accompanies: the window may not exist at all.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }

        runningTask = nil
        // Success or failure, a mutation can have changed what is installed — and until that
        // refresh lands, the operation keeps holding its card: dropping busy on completion
        // alone showed the pre-mutation overlays for the second the probes take. The hold is
        // released by whichever refresh actually publishes (releaseRefreshHolds), not here —
        // this run can be superseded and bail without publishing.
        Task {
            // Cleanup shrinks Cellar racks under unchanged id|version cache keys, so the
            // whole session cache goes; it refills lazily. (The size-sort order corrects on the
            // next sweep — its trigger key is unchanged by cleanup, a documented residual.)
            if operation.command == .cleanup { DiskUsage.cache.removeAll() }
            await self.refreshState()
        }
        if state == .succeeded, operation.command.isMutating { batchHadSuccessfulMutation = true }
        if state == .failed { batchHadFailure = true }
        pump()
        // An install runs for minutes and people go elsewhere while it does: failure bounces
        // the Dock, and success while the app is inactive said nothing. One knock when the
        // batch drains — never alongside a failure's, which already fired.
        if !isQueueActive {
            if batchHadSuccessfulMutation, !batchHadFailure, !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
            }
            batchHadSuccessfulMutation = false
            batchHadFailure = false
        }
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

    /// LaunchServices picks the viewer: a font file opens in Font Book, a log in Console —
    /// the platform's own apps for both, never rebuilt in here.
    func openFile(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The service's log as a real file: `$HOMEBREW_PREFIX` substituted, existence
    /// checked per call — the affordance appears once the service has actually logged.
    func serviceLogURL(for package: Package) -> URL? {
        guard let path = package.service?.logPath else { return nil }
        let url = URL(filePath: Package.substitutingPrefix(path, prefix: client.prefix))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    /// The quit guard's question: anything mutating that quitting would abandon — running,
    /// or queued behind the pump's freshness hold.
    var hasUnfinishedMutations: Bool {
        operations.contains { !$0.isFinished && $0.command.isMutating }
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

    /// Homebrew ▸ Add Tap… lands on the tap list first: the popover hangs off a toolbar
    /// button that a drilled-in tap page does not show.
    func requestAddTap() {
        selection = .taps
        selectedTap = nil
        showAddTap = true
    }

    /// The pane's Browse All escape: the Taps section drills into this tap.
    func requestOpenTap(_ tap: String) {
        selection = .taps
        selectedTap = tap
    }

    /// Checkup's "Show in Taps": the list, where Remove Tap… lives.
    func requestShowTapList() {
        selection = .taps
        selectedTap = nil
    }
}

/// Accumulator for the checkup's split streams; a class so the `@Sendable` line callbacks can
/// append into it (BrewClient's own `LineBuffer` pattern — all access is MainActor).
private final class CheckupBuffer {
    var lines: [String] = []
}
