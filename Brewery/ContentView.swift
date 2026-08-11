//
//  ContentView.swift
//  Brewery
//
//  Created by vzbarashchenko on 09.08.2026.
//

import SwiftUI
import TipKit

/// What a first-time, non-technical user needs told once: the two words this whole store runs
/// on. TipKit renders it as the native dismissible tip card, and remembers the dismissal.
struct PackageKindsTip: Tip {
    var title: Text {
        Text("Tools and apps, together")
    }

    var message: Text? {
        Text("Formulae are command-line tools for the Terminal. Casks are regular Mac apps. Everything installs with one click — use the filter to browse one kind.")
    }

    var image: Image? {
        Image(systemName: "shippingbox")
    }
}

/// The fixed destinations of the sidebar.
nonisolated enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case discover, installed, outdated, services, taps

    var id: Self { self }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .installed: "Installed"
        case .outdated: "Outdated"
        case .services: "Services"
        case .taps: "Taps"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "sparkle.magnifyingglass"
        case .installed: "checkmark.circle"
        case .outdated: "arrow.triangle.2.circlepath"
        // Most brew services are servers — redis, postgres, nginx.
        case .services: "server.rack"
        // The same glyph the detail sheet's tap row wears.
        case .taps: "spigot"
        }
    }

    var searchPrompt: String {
        switch self {
        case .discover: "Search Homebrew"
        case .installed: "Search Installed"
        case .outdated: "Search Outdated"
        case .services: "Search Services"
        case .taps: "Search Taps"
        }
    }

    /// Shown by the grid when the section has nothing to list and no search is active.
    var emptyMessage: String? {
        switch self {
        case .discover: nil
        case .installed: "No packages installed"
        case .outdated: "Everything is up to date"
        case .services: "No services"
        case .taps: "This tap provides no packages"
        }
    }
}

/// Discover's kind filter. Applied to the array before it reaches the ranker, which is why it is
/// plain state and not `.searchScopes`: scopes only surface while a search is active, and the
/// filter has to govern empty-query browsing just the same.
nonisolated enum KindFilter: String, CaseIterable, Identifiable {
    case all, formulae, casks, fonts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .formulae: "Formulae"
        case .casks: "Casks"
        case .fonts: "Fonts"
        }
    }

    func matches(_ package: Package) -> Bool {
        switch self {
        case .all: true
        case .formulae: package.kind == .formula
        // Fonts are casks, but Casks has to mean "apps" here: leaving them in would make Fonts a
        // subset of a filter the user just picked, and the option pointless.
        case .casks: package.kind == .cask && !package.isFont
        case .fonts: package.isFont
        }
    }
}

/// The Installed section's scope: what the user asked for, or everything that is on disk.
nonisolated enum InstalledScope: String, CaseIterable, Identifiable {
    case onRequest, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onRequest: "On Request"
        case .all: "All"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @AppStorage("discover.kindFilter") private var kindFilter: KindFilter = .all
    @AppStorage("discover.hideDeprecated") private var hideDeprecated = false
    @AppStorage("installed.scope") private var installedScope: InstalledScope = .onRequest
    /// A source is not a kind: a tap item IS a formula or cask, so "from taps" is a combinable
    /// toggle like Hide Deprecated, never a kind-picker case — "casks from taps" must be sayable.
    @AppStorage("discover.tapsOnly") private var tapsOnly = false
    /// Installed's own kind filter — deliberately separate state from Discover's: switching tabs
    /// must not carry one tab's filter into the other.
    @AppStorage("installed.kindFilter") private var installedKindFilter: KindFilter = .all
    @AppStorage("installed.tapsOnly") private var installedTapsOnly = false

    @State private var selection: SidebarSection? = .discover
    /// The Taps section's in-column drill-down: nil shows the tap list, a name shows that tap's
    /// package grid. "homebrew/core"/"homebrew/cask" select the API-backed catalogs. Manual rather
    /// than `NavigationStack` — macOS does not animate stack pushes in a split view's detail
    /// column, and the drill-down deserves the slide the detail sheet's dependency pages have.
    @State private var selectedTap: String?
    /// The tap page's kind filter. Deliberately transient (@State, reset per page): a persisted
    /// filter that silently empties the next tap's page would read as data loss.
    @State private var tapKindFilter: KindFilter = .all
    /// Ranked results per section, so leaving a tab and coming back shows that tab's results at
    /// once. A single array meant visiting a tab with an empty query cleared it, and the return
    /// trip flashed the unfiltered listing until the re-rank landed.
    @State private var results: [SidebarSection: [SearchHit]] = [:]
    /// The browse listing, built once per change of the underlying array rather than per body pass.
    /// Rebuilding it inline cost two full walks of the 16k catalog every time the body ran — and,
    /// worse, handed SwiftUI a fresh array each time, so its cheap CoW identity check for "did this
    /// change?" degraded into a 16k element-by-element comparison.
    @State private var browseHits: [SearchHit] = []
    @State private var selectedPackage: Package?
    @State private var showOperations = false
    @State private var showAddTap = false
    @FocusState private var searchFocused: Bool

    /// How many cards are handed to the grid. It grows as the end of the list is reached and resets
    /// whenever the listing changes. It lives here, not in the grid, because the slicing has to
    /// happen on *this* side of the view boundary — see the note on `PackageGridView`.
    private static let windowStep = 60
    @State private var window = ContentView.windowStep

    var body: some View {
        Group {
            if model.brewMissing {
                brewNotFound
            } else {
                splitView
            }
        }
        .sheet(item: $selectedPackage) { package in
            PackageDetailView(package: package)
        }
    }

    // MARK: - Shell

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badgeCount(for: item))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            chrome(detail)
        }
        .task(id: searchKey) {
            let ranked = section
            guard isSearching else {
                results[ranked] = nil
                return
            }
            // Debounce. The sleep throws when the next keystroke replaces this task — a bare
            // `try? await` would swallow that and let the stale ranking assign anyway.
            // Short on purpose: ranking is a few milliseconds and runs off the main actor, so the
            // debounce only has to coalesce a fast typist's burst, not hide a slow search.
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
            results[ranked] = await FuzzySearch.rank(query: searchText,
                                                     in: sourcePackages,
                                                     commands: model.commandIndex)
        }
        .task(id: browseKey) {
            var packages = sourcePackages
            // Discover browses by popularity, not by name: an alphabetical walk of 16k packages
            // opens on "0 A.D." and never reaches anything anyone installs. Installed and Outdated
            // are inventories, where alphabetical is the order you scan.
            if section == .discover || (section == .taps && TapStore.coreTaps.contains(selectedTap ?? "")) {
                packages.sort(by: Self.byPopularity)
            }
            browseHits = packages.map { SearchHit(package: $0, matchedCommand: nil) }
        }
        .onChange(of: searchKey.window) { window = Self.windowStep }
        .onChange(of: selection) { if selection != .taps { selectedTap = nil } }
        .onChange(of: selectedTap) { tapKindFilter = .all }
        .onChange(of: model.findRequests) { searchFocused = true }
        .onChange(of: model.failureToPresent?.id) { _, failure in
            guard failure != nil else { return }
            showOperations = true
            model.failureToPresent = nil
        }
    }

    @ViewBuilder private var detail: some View {
        // The catalog gates Discover only: Installed and Outdated stand on their own, synthesizing
        // packages for anything the catalog does not cover.
        if section == .discover, model.catalog.isEmpty, model.catalogFailed {
            catalogFailed
        } else if section == .discover, model.catalog.isEmpty {
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if section == .taps {
            // The detail sheet's drill-down grammar: the list stays mounted underneath — scroll
            // position survives the round trip — receding as the page slides in over it.
            ZStack {
                TapsView(searchText: searchText, onSelect: { openTap($0) })
                    .opacity(selectedTap == nil ? 1 : 0)
                    .offset(x: selectedTap == nil ? 0 : -60)
                    // Disabled, not just covered: a hidden list's rows must not sit in the
                    // Tab order underneath the grid.
                    .disabled(selectedTap != nil)
                    .accessibilityHidden(selectedTap != nil)
                if let tap = selectedTap {
                    tapPage(tap)
                        // Opaque, so the receding list never shows through between the cards.
                        .background(.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .refreshVeil(model.isRefreshing)
        } else if section == .services {
            // State rows, not catalog cards — a handful of items, no windowing needed.
            ServicesView(hits: displayedHits,
                         isSearching: isSearching,
                         onSelect: { selectedPackage = $0 },
                         onRefresh: { refresh() })
                .refreshVeil(model.isRefreshing)
        } else {
            PackageGridView(hits: Array(displayedHits.prefix(window)),
                            totalCount: displayedCount,
                            isSearching: isSearching,
                            onSelect: { selectedPackage = $0 },
                            emptyMessage: emptyMessage,
                            onNeedMore: { window += Self.windowStep },
                            onRefresh: emptyStateRefresh,
                            header: { discoverTip })
                .refreshVeil(model.isRefreshing)
        }
    }

    /// The column's chrome: title, toolbar, search field.
    private func chrome(_ content: some View) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                filterToolbar
                refreshToolbar
                operationsToolbar
            }
            .searchable(text: searchQuery, prompt: searchPrompt)
            .searchFocused($searchFocused)
    }

    /// A tap's package grid, slid above the tap list.
    private func tapPage(_ tap: String) -> some View {
        PackageGridView(hits: Array(displayedHits.prefix(window)),
                        totalCount: displayedCount,
                        isSearching: isSearching,
                        onSelect: { selectedPackage = $0 },
                        emptyMessage: emptyMessage,
                        onNeedMore: { window += Self.windowStep },
                        onRefresh: emptyStateRefresh,
                        header: { TapPageHeader(tap: tap) })
    }

    /// The push. The listing is built *before* the slide starts: the browse task rebuilds it
    /// asynchronously, and a grid that slides in empty and fills mid-flight reads as no
    /// animation at all.
    private func openTap(_ tap: String) {
        tapKindFilter = .all
        browseHits = browseListing(for: tap)
        withAnimation(.smooth(duration: 0.3)) { selectedTap = tap }
    }

    /// Discover only, and only while browsing: the tip is a newcomer's explainer, not search
    /// feedback — and a TipView sharing the tree with `ContentUnavailableView.search` blanks
    /// the split view's sidebar (framework interaction, reproduced and pinned by UI test).
    @ViewBuilder private var discoverTip: some View {
        if section == .discover, !isSearching {
            TipView(PackageKindsTip())
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    // MARK: - Search

    private var section: SidebarSection { selection ?? .discover }

    nonisolated private static func byPopularity(_ a: Package, _ b: Package) -> Bool {
        let (x, y) = (a.installs90d ?? 0, b.installs90d ?? 0)
        return x == y ? a.name < b.name : x > y
    }

    /// What the browse task will (re)build for this tap, computed synchronously — cheap even for
    /// core: one filter of the catalog and one sort of ~8k entries, a few milliseconds on a click.
    private func browseListing(for tap: String) -> [SearchHit] {
        var packages = tapPagePackages(for: tap)
        if TapStore.coreTaps.contains(tap) { packages.sort(by: Self.byPopularity) }
        return packages.map { SearchHit(package: $0, matchedCommand: nil) }
    }

    /// The tap page titles itself with the tap's name — otherwise nothing on screen says which
    /// tap's packages the grid is showing.
    private var title: String {
        if section == .taps, let tap = selectedTap { return tap }
        return section.title
    }

    /// On a tap's page the search searches that tap's packages, not the tap list.
    private var searchPrompt: String {
        if section == .taps, selectedTap != nil { return "Search Packages" }
        return section.searchPrompt
    }

    /// Per-tab, and in the model rather than in `@State`: switching sections destroys the detail
    /// view along with anything it holds, so a query stored here would not survive the round trip.
    private var searchText: String { model.queries[section] ?? "" }

    private var searchQuery: Binding<String> {
        Binding(get: { model.queries[section] ?? "" },
                set: { model.queries[section] = $0 })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func badgeCount(for item: SidebarSection) -> Int {
        switch item {
        case .outdated: model.outdatedCount
        case .services: model.runningServicesCount
        default: 0
        }
    }

    private var sourcePackages: [Package] {
        switch section {
        case .discover: filtered(model.catalog)
        case .installed: installedFiltered(model.installedPackages(scope: installedScope))
        case .outdated: model.outdatedPackages
        case .services: model.servicePackages
        case .taps: tapPagePackages
        }
    }

    /// A tap page's contents. Core rows are the API catalog sliced by kind; third-party rows are
    /// the scan's packages for that tap. The list view (selectedTap == nil) needs no packages.
    private var tapPagePackages: [Package] { tapPagePackages(for: selectedTap) }

    private func tapPagePackages(for tap: String?) -> [Package] {
        let packages: [Package] = switch tap {
        case nil: []
        case "homebrew/core": model.catalog.filter { $0.kind == .formula && $0.tap == nil }
        case "homebrew/cask": model.catalog.filter { $0.kind == .cask && $0.tap == nil }
        case let tap?: model.tapPackages(for: tap)
        }
        guard tapKindFilter != .all else { return packages }
        return packages.filter(tapKindFilter.matches)
    }

    /// Installed's kind pre-filter — same position in the pipeline as Discover's: before ranking,
    /// and governing empty-query browsing too. A few hundred items, so no caching needed.
    private func installedFiltered(_ packages: [Package]) -> [Package] {
        guard installedKindFilter != .all || installedTapsOnly else { return packages }
        return packages.filter { package in
            // The effective tap, not `package.tap`: an installed tap item whose name collides
            // with core joins the core catalog entry, but its receipt knows the truth.
            installedKindFilter.matches(package)
                && !(installedTapsOnly && model.effectiveTap(for: package) == nil)
        }
    }

    /// Discover's pre-filter. It runs before `FuzzySearch.rank`, so ranking only ever sees fewer
    /// candidates, and because it sits on the source array it governs browsing with no query too.
    private func filtered(_ packages: [Package]) -> [Package] {
        guard filtersActive else { return packages }
        return packages.filter { package in
            // A disabled package is further along the same lifecycle as a deprecated one, and
            // cannot be installed at all.
            kindFilter.matches(package)
                && !(hideDeprecated && (package.deprecated || package.disabled))
                && !(tapsOnly && package.tap == nil)
        }
    }

    private var filtersActive: Bool { kindFilter != .all || hideDeprecated || tapsOnly }

    /// Discover has no empty state of its own — by the time it renders, the catalog is loaded — but
    /// a filter can empty it, and so can the On Request scope on a machine whose kegs are all deps.
    private var emptyMessage: String? {
        switch section {
        case .discover:
            filtersActive ? "No packages match the filters" : nil
        case .installed:
            if installedKindFilter != .all || installedTapsOnly, !model.installed.isEmpty {
                "No installed packages match the filter"
            } else if installedScope == .onRequest, !model.installed.isEmpty {
                "No packages installed on request"
            } else {
                section.emptyMessage
            }
        case .outdated, .services:
            section.emptyMessage
        case .taps:
            tapKindFilter != .all ? "No packages match the filter" : section.emptyMessage
        }
    }

    /// An empty query bypasses ranking entirely, so the section array — already alphabetical —
    /// is rendered straight from the model and stays live as operations finish. Results from
    /// another section are equally unusable: during the debounce after a section switch the new
    /// section's own array stands in, never the old section's cards.
    private var displayedHits: [SearchHit] {
        guard isSearching else { return browseHits }
        // Falling back to the listing only happens the very first time a section is searched,
        // before its first ranking lands.
        return results[section] ?? browseHits
    }

    /// What the grid will render. Reads the cached array rather than rebuilding it to count it.
    private var displayedCount: Int {
        guard isSearching else { return browseHits.count }
        return (results[section] ?? browseHits).count
    }

    /// What the browse listing is made of. Deliberately excludes the query: while a search is being
    /// typed the grid still shows this listing, so rebuilding it per keystroke would be pure waste.
    private struct BrowseKey: Equatable {
        let section: SidebarSection
        let kindFilter: KindFilter
        let hideDeprecated: Bool
        let installedScope: InstalledScope
        let installedKindFilter: KindFilter
        let tapsOnly: Bool
        let installedTapsOnly: Bool
        let selectedTap: String?
        let tapKindFilter: KindFilter
        /// Not a count: a tap rescan can swap entries while netting zero, which a count cannot see.
        let catalogGeneration: Int
        let installedCount: Int
        let outdatedCount: Int
        let servicesCount: Int
    }

    private var browseKey: BrowseKey {
        BrowseKey(section: section,
                  kindFilter: kindFilter,
                  hideDeprecated: hideDeprecated,
                  installedScope: installedScope,
                  installedKindFilter: installedKindFilter,
                  tapsOnly: tapsOnly,
                  installedTapsOnly: installedTapsOnly,
                  selectedTap: selectedTap,
                  tapKindFilter: tapKindFilter,
                  catalogGeneration: model.catalogGeneration,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count,
                  servicesCount: model.serviceStatuses.count)
    }

    private var searchKey: SearchKey {
        SearchKey(window: WindowToken(section: section,
                                      query: searchText,
                                      kindFilter: kindFilter,
                                      hideDeprecated: hideDeprecated,
                                      installedScope: installedScope,
                                      installedKindFilter: installedKindFilter,
                                      tapsOnly: tapsOnly,
                                      installedTapsOnly: installedTapsOnly,
                                      selectedTap: selectedTap,
                                      tapKindFilter: tapKindFilter),
                  catalogGeneration: model.catalogGeneration,
                  commandCount: model.commandIndex.count,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count,
                  servicesCount: model.serviceStatuses.count)
    }

    /// Re-ranks on a new query, a section switch, a filter change, or any change to the arrays
    /// being searched.
    private struct SearchKey: Equatable {
        let window: WindowToken
        /// Deliberately here and not in `WindowToken`: a tap rescan re-ranks but never resets
        /// the scroll window.
        let catalogGeneration: Int
        /// The command index lands a beat after the catalog it is derived from; without this a
        /// query typed during launch would keep results that never saw the index.
        let commandCount: Int
        let installedCount: Int
        let outdatedCount: Int
        let servicesCount: Int
    }

    /// The part of the key that changes *which* packages are listed — the grid restarts its render
    /// window on it. A refresh landing new versions deliberately does not.
    private struct WindowToken: Hashable {
        let section: SidebarSection
        let query: String
        let kindFilter: KindFilter
        let hideDeprecated: Bool
        let installedScope: InstalledScope
        let installedKindFilter: KindFilter
        let tapsOnly: Bool
        let installedTapsOnly: Bool
        let selectedTap: String?
        let tapKindFilter: KindFilter
    }

    // MARK: - Counts

    /// `.navigationSubtitle` is where macOS puts a count (Mail's message counts live there). It
    /// reports what the grid actually renders, so a search or a filter narrows it too.
    private var subtitle: String {
        guard section != .discover || !model.catalog.isEmpty else { return "" }

        let count = displayedCount
        let formatted = count.formatted(.number)
        guard !isSearching, !isNarrowed else {
            return count == 1 ? "1 result" : "\(formatted) results"
        }
        switch section {
        case .discover: return count == 1 ? "1 package" : "\(formatted) packages"
        case .installed: return "\(formatted) installed"
        case .outdated: return "\(formatted) outdated"
        case .services: return count == 1 ? "1 service" : "\(formatted) services"
        case .taps:
            if selectedTap != nil { return count == 1 ? "1 package" : "\(formatted) packages" }
            let taps = model.tapInfos.count + 2   // + the two built-in rows
            return "\(taps) taps"
        }
    }

    /// Whether the section is showing something other than its plain default listing.
    private var isNarrowed: Bool {
        switch section {
        case .discover: filtersActive
        case .installed: installedScope != .onRequest || installedKindFilter != .all || installedTapsOnly
        case .outdated, .services: false
        case .taps: selectedTap != nil && tapKindFilter != .all
        }
    }

    // MARK: - Filters

    /// Each section carries only its own control. Outdated's is the bulk action itself: the menu
    /// bar's ⇧⌘U is invisible from here, and the section whose whole job is updating should not
    /// make the user update one card at a time.
    @ToolbarContentBuilder private var filterToolbar: some ToolbarContent {
        if section == .taps {
            if selectedTap != nil {
                // In-column drill-down: back belongs in the navigation slot.
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { selectedTap = nil }
                    } label: {
                        Label("Taps", systemImage: "chevron.backward")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to the tap list")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Kind", selection: $tapKindFilter) {
                            ForEach(KindFilter.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Filter", systemImage: tapKindFilter != .all
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter by kind")
                    .accessibilityLabel("Filter")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddTap = true
                    } label: {
                        Label("Add Tap", systemImage: "plus")
                    }
                    .help("Add a tap")
                    .accessibilityLabel("Add Tap")
                    .popover(isPresented: $showAddTap, arrowEdge: .bottom) {
                        AddTapPopover(onAdd: { model.addTap($0) })
                    }
                }
            }
        }
        if section == .outdated, model.outdatedCount > 0 {
            ToolbarItem(placement: .primaryAction) {
                Button("Update All") { model.upgradeAll() }
                    .disabled(upgradeAllPending)
                    .help("Update all outdated packages")
            }
        }
        if section == .discover {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Kind", selection: $kindFilter) {
                        ForEach(KindFilter.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)

                    Toggle("Hide Deprecated", isOn: $hideDeprecated)
                    Toggle("From Taps Only", isOn: $tapsOnly)
                } label: {
                    // The filled variant is the tell that the grid is not showing everything.
                    Label("Filter", systemImage: filtersActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("Filter")
                .accessibilityLabel("Filter")
            }
        }
        if section == .installed {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Kind", selection: $installedKindFilter) {
                        ForEach(KindFilter.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)

                    Toggle("From Taps Only", isOn: $installedTapsOnly)
                } label: {
                    Label("Filter", systemImage: installedKindFilter != .all || installedTapsOnly
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("Filter by kind")
                .accessibilityLabel("Filter")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Scope", selection: $installedScope) {
                    ForEach(InstalledScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Show packages you installed, or everything on disk including dependencies")
                .accessibilityLabel("Installed Scope")
            }
        }
    }

    // MARK: - Refresh

    /// The same work ⌘R does, with somewhere to look while it happens: the glyph turns for as long
    /// as the refresh runs.
    @ToolbarContentBuilder private var refreshToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeating, isActive: model.isRefreshing)
            }
            .disabled(model.isRefreshing)
            .help("Refresh installed packages and check for updates")
            .accessibilityLabel("Refresh")
        }
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    /// An Upgrade All already on the queue makes a second press pure duplication.
    private var upgradeAllPending: Bool {
        model.operations.contains {
            $0.command == .upgradeAll && ($0.state == .queued || $0.state == .running)
        }
    }

    /// Not offered on Discover: an empty grid there means a filter is hiding things, and
    /// re-checking will not bring them back.
    private var emptyStateRefresh: (() -> Void)? {
        guard section != .discover else { return nil }
        return { refresh() }
    }

    // MARK: - Operations

    @ToolbarContentBuilder private var operationsToolbar: some ToolbarContent {
        if !model.operations.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showOperations.toggle()
                } label: {
                    if model.isQueueActive {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                            // Rolls between values, so a queue draining reads as a count going
                            // down rather than as unrelated numbers replacing each other.
                            Text(model.activeCount, format: .number)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(model.activeCount)))
                                .animation(.smooth(duration: 0.25), value: model.activeCount)
                        }
                    } else {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                .help("Operations")
                .accessibilityLabel("Operations")
                .popover(isPresented: $showOperations, arrowEdge: .bottom) {
                    OperationsPopover()
                }
            }
        }
    }

    // MARK: - Unavailable states

    private var brewNotFound: some View {
        ContentUnavailableView {
            Label("Homebrew Not Found", systemImage: "shippingbox")
        } description: {
            Text("Brewery drives the brew command line tool. Install Homebrew, then refresh.")
        } actions: {
            Link("Install Homebrew", destination: URL(string: "https://brew.sh")!)
                .buttonStyle(.borderedProminent)
            Button("Refresh") {
                Task { await model.refresh() }
            }
        }
    }

    private var catalogFailed: some View {
        ContentUnavailableView {
            Label("Couldn't Load Catalog", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("Brewery downloads the Homebrew package list from formulae.brew.sh. Check your connection and try again.")
        } actions: {
            Button("Retry") {
                Task { await model.retryCatalog() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// ⌘R feedback in the content itself, not just the toolbar glyph: the listing stays put but
    /// recedes — blurred and dimmed, never hidden, because the data on screen is still valid while
    /// it is re-checked — behind a glass capsule naming the work. On a warm cache the whole thing
    /// is a soft half-second pulse, which is exactly the acknowledgment a fast refresh needs.
    /// Worn by the grid and by an open detail sheet's content alike — the sheet is frontmost, so
    /// without its own veil a ⌘R would look ignored.
    func refreshVeil(_ active: Bool) -> some View {
        blur(radius: active ? 6 : 0)
            .opacity(active ? 0.5 : 1)
            .overlay {
                if active {
                    Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect()
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.3), value: active)
    }
}

/// The Safari-downloads pattern: everything this session did, newest first, each row unfolding
/// into its live log.
private struct OperationsPopover: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<BrewOperation.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Operations")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.operations.reversed()) { operation in
                        row(operation)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 380)
    }

    @ViewBuilder private func row(_ operation: BrewOperation) -> some View {
        let isExpanded = expanded.contains(operation.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: operation.symbolName)
                    .foregroundStyle(tint(for: operation.state))
                    .symbolEffect(.rotate, options: .repeating, isActive: operation.state == .running)

                VStack(alignment: .leading, spacing: 1) {
                    Text(operation.title)
                        .lineLimit(1)
                    Text(description(for: operation.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                switch operation.state {
                case .running:
                    Button("Cancel") { model.cancel(operation) }
                        .controlSize(.small)
                case .queued:
                    Button {
                        model.remove(operation)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove from queue")
                default:
                    EmptyView()
                }

                Button {
                    if isExpanded {
                        expanded.remove(operation.id)
                    } else {
                        expanded.insert(operation.id)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide Log" : "Show Log")
                .accessibilityLabel(isExpanded ? "Hide Log" : "Show Log")
            }

            if isExpanded {
                OperationLogView(operation: operation)
                    .frame(height: 160)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tint(for state: BrewOperation.State) -> Color {
        switch state {
        case .queued, .cancelled: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }

    private func description(for state: BrewOperation.State) -> String {
        switch state {
        case .queued: "Waiting"
        case .running: "Running…"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
