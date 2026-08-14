//
//  ContentView.swift
//  Brewery
//
//  Created by vzbarashchenko on 09.08.2026.
//

import AppKit
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

    /// The View menu's key equivalent for this destination, in `allCases` order.
    var shortcut: KeyEquivalent {
        switch self {
        case .discover: "1"
        case .installed: "2"
        case .outdated: "3"
        case .services: "4"
        case .taps: "5"
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
    /// Every x-axis slide and sustained rotation below has a crossfade or a still glyph behind this.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The Taps section's in-column drill-down: nil shows the tap list, a name shows that tap's
    /// package grid. "homebrew/core"/"homebrew/cask" select the API-backed catalogs.
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
    @State private var showAddTap = false
    @FocusState private var searchFocused: Bool

    /// How many cards are handed to the grid. It grows as the end of the list is reached and resets
    /// whenever the listing changes. It lives here, not in the grid, because the slicing has to
    /// happen on *this* side of the view boundary — see the note on `PackageGridView`.
    private static let windowStep = 60
    @State private var window = ContentView.windowStep

    var body: some View {
        if model.brewMissing {
            brewNotFound
        } else {
            splitView
        }
    }

    /// Opening a package means selecting it, not interrupting: the pane follows the selection, so
    /// clicking through card after card is one continuous act rather than open-read-dismiss.
    private func select(_ package: Package) {
        selectedPackage = package
        model.showInspector = true
    }

    // MARK: - Shell

    private var splitView: some View {
        @Bindable var model = model

        return NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badgeCount(for: item))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    filterToolbar
                    refreshToolbar
                    operationsToolbar
                    inspectorToolbar
                }
                .searchable(text: searchQuery, prompt: searchPrompt)
                .searchFocused($searchFocused)
                // Return opens the top hit — the keyboard path from typing a name to reading about
                // it, without reaching for the pointer.
                .onSubmit(of: .search) {
                    if let hit = displayedHits.first { select(hit.package) }
                }
                // A pane, not a sheet: the listing stays live beside it, it resizes with the
                // window, and nothing has to be dismissed before the next card can be clicked.
                .inspector(isPresented: $model.showInspector) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
                }
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
        .onChange(of: model.selection) { if section != .taps { selectedTap = nil } }
        .onChange(of: selectedTap) { tapKindFilter = .all }
        .onChange(of: model.findRequests) { searchFocused = true }
        // Homebrew ▸ Add Tap… lands on the tap list first: the popover hangs off a toolbar button
        // that a drilled-in tap page does not show.
        .onChange(of: model.addTapRequests) {
            selectedTap = nil
            showAddTap = true
        }
        .onChange(of: model.failureToPresent?.id) { _, failure in
            guard failure != nil else { return }
            model.showOperations = true
            model.failureToPresent = nil
            // An install runs for minutes and people go elsewhere while it does. A popover opening
            // behind another app is not feedback; one Dock bounce is.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
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
            // The detail sheet's drill-down grammar (manual — macOS NavigationStack does not
            // animate pushes in a split view's detail column): the list stays mounted, keeping
            // its scroll position, and recedes while the tap's page slides in over it.
            ZStack {
                TapsView(searchText: searchText, onSelect: openTap)
                    .opacity(selectedTap == nil ? 1 : 0)
                    .offset(x: selectedTap == nil || reduceMotion ? 0 : -60)
                    // Disabled, not just covered: the hidden rows must leave the Tab order.
                    .disabled(selectedTap != nil)
                    .accessibilityHidden(selectedTap != nil)
                if let tap = selectedTap {
                    packageGrid(tap: tap)
                        // Opaque, so the receding list never shows through between the cards.
                        .background(.background)
                        // Reduce Motion turns the push into the crossfade it asks x-axis
                        // transitions to become.
                        .transition(reduceMotion ? .opacity
                                                 : .move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .refreshVeil(model.isRefreshing)
        } else if section == .services {
            // State rows, not catalog cards — a handful of items, no windowing needed.
            ServicesView(hits: displayedHits,
                         isSearching: isSearching,
                         selectedID: inspectedID,
                         onSelect: { select($0) },
                         onRefresh: { refresh() })
                .refreshVeil(model.isRefreshing)
        } else {
            packageGrid()
                .refreshVeil(model.isRefreshing)
        }
    }

    /// `.id` on the package: the pane keeps a drill-down stack, and clicking a different card has
    /// to start a fresh one rather than leave you inside the previous package's dependencies.
    @ViewBuilder private var inspector: some View {
        if let package = selectedPackage {
            PackageDetailView(package: package)
                .id(package.id)
        } else {
            // Reachable: ⌘I opens the pane whether or not anything is selected.
            ContentUnavailableView {
                Label("No Selection", systemImage: "shippingbox")
            } description: {
                Text("Select a package to see what it is, where it comes from, and what it needs.")
            }
        }
    }

    private func packageGrid(tap: String? = nil) -> some View {
        PackageGridView(hits: Array(displayedHits.prefix(window)),
                        totalCount: displayedCount,
                        isSearching: isSearching,
                        selectedID: inspectedID,
                        onSelect: { select($0) },
                        emptyMessage: emptyMessage,
                        onNeedMore: { window += Self.windowStep },
                        onRefresh: emptyStateRefresh,
                        isChecking: section == .outdated && model.isCheckingForUpdates,
                        header: {
                            if let tap {
                                TapPageHeader(tap: tap)
                            } else if section == .outdated {
                                freshnessCaption
                            } else {
                                discoverTip
                            }
                        })
    }

    /// v8 — the Outdated page's status feedback, integrated into the page rather than raised at
    /// it (HIG *Feedback*): a small spinner naming the launch-time check while it runs, else how
    /// long ago brew's metadata was last refreshed — the answer to "is this list stale?" that
    /// used to require a terminal. Lives in the header slot so it scrolls with content and sits
    /// in a consistent location in both the grid and the empty state; when the section is empty
    /// the checking spinner is the empty state itself, so this caption keeps to the timestamp.
    @ViewBuilder private var freshnessCaption: some View {
        Group {
            if model.isCheckingForUpdates, displayedCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates…")
                }
                // Combined here, not on the whole caption: fused onto the plain-text branch it
                // demoted the caption from a static text to a group, hiding it from VoiceOver's
                // text navigation (and from UI tests) alike.
                .accessibilityElement(children: .combine)
            } else if let checked = model.metadataCheckedAt {
                // Minute cadence: a live seconds counter in a calm caption draws the eye for no
                // benefit. The string must be computed *from context.date*: a Text whose stored
                // inputs never change diffs as unchanged, so the schedule alone redraws nothing —
                // verified the hard way, a caption frozen at "2 seconds ago".
                TimelineView(.everyMinute) { context in
                    Text("Last checked \(Self.checkedFormatter.localizedString(for: checked, relativeTo: context.date))")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// "now", "5 minutes ago", "2 hours ago" — anchored to the timeline tick, not to format time.
    private static let checkedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// The listing is built *before* the slide starts: the browse task rebuilds it
    /// asynchronously, and a grid that slides in empty and fills mid-flight reads as a cut.
    private func openTap(_ tap: String) {
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

    private var section: SidebarSection { model.selection ?? .discover }

    nonisolated private static func byPopularity(_ a: Package, _ b: Package) -> Bool {
        let (x, y) = (a.installs90d ?? 0, b.installs90d ?? 0)
        return x == y ? a.name < b.name : x > y
    }

    /// The tap page's listing, same as the browse task would build it — cheap enough for a click
    /// even on core (one filter, one ~8k sort).
    private func browseListing(for tap: String) -> [SearchHit] {
        var packages = tapPagePackages(for: tap)
        if TapStore.coreTaps.contains(tap) { packages.sort(by: Self.byPopularity) }
        return packages.map { SearchHit(package: $0, matchedCommand: nil) }
    }

    /// A tap page titles the window with its tap's name.
    private var title: String {
        if section == .taps, let tap = selectedTap { return tap }
        return section.title
    }

    /// On a tap page the search field searches that tap's packages, not the tap list.
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
        case .outdated: model.outdated.count
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
        case .taps: tapPagePackages(for: selectedTap)
        }
    }

    /// A tap page's contents. Core rows are the API catalog sliced by kind; third-party rows are
    /// the scan's packages for that tap. The list view (tap == nil) needs no packages.
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

    /// What the grid will render.
    private var displayedCount: Int { displayedHits.count }

    /// Which row the pane is describing, so the listing can say so. A split view has to keep the
    /// current selection visible in the pane that leads to the detail — and nil while the pane is
    /// closed, because nothing is being described. One `String?` across the boundary, not an array.
    private var inspectedID: Package.ID? {
        model.showInspector ? selectedPackage?.id : nil
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
                        kindPicker($tapKindFilter)
                    } label: {
                        filterLabel(active: tapKindFilter != .all)
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
        if section == .outdated, !model.outdated.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Update All") { model.upgradeAll() }
                    .disabled(upgradeAllPending)
                    .help("Update all outdated packages")
            }
        }
        if section == .discover {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    kindPicker($kindFilter)
                    Toggle("Hide Deprecated", isOn: $hideDeprecated)
                    Toggle("From Taps Only", isOn: $tapsOnly)
                } label: {
                    filterLabel(active: filtersActive)
                }
                .help("Filter")
                .accessibilityLabel("Filter")
            }
        }
        if section == .installed {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    kindPicker($installedKindFilter)
                    Toggle("From Taps Only", isOn: $installedTapsOnly)
                } label: {
                    filterLabel(active: installedKindFilter != .all || installedTapsOnly)
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

    private func kindPicker(_ selection: Binding<KindFilter>) -> some View {
        Picker("Kind", selection: selection) {
            ForEach(KindFilter.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.inline)
    }

    /// The filled variant is the tell that the grid is not showing everything.
    private func filterLabel(active: Bool) -> some View {
        Label("Filter", systemImage: active
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle")
    }

    // MARK: - Refresh

    /// The same work ⌘R does, with somewhere to look while it happens: the glyph turns for as long
    /// as the refresh runs.
    @ToolbarContentBuilder private var refreshToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeating,
                                  isActive: model.isRefreshing && !reduceMotion)
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

    /// The pane's toggle, on the trailing edge where macOS puts the buttons that open nearby
    /// inspectors — and last, so it sits closest to the pane it opens.
    @ToolbarContentBuilder private var inspectorToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .keyboardShortcut("i")
            .help(model.showInspector ? "Hide the info pane" : "Show the info pane")
            .accessibilityLabel(model.showInspector ? "Hide Info" : "Show Info")
        }
    }

    @ToolbarContentBuilder private var operationsToolbar: some ToolbarContent {
        @Bindable var model = model

        if !model.operations.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showOperations.toggle()
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
                    } else if model.lastOperationFailed {
                        // A different glyph, not just a red one: the failure has to survive
                        // dismissing the popover, and it has to survive colour-blindness too.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                .help(model.lastOperationFailed ? "Operations — the last one failed" : "Operations")
                .accessibilityLabel(model.lastOperationFailed ? "Operations, last operation failed"
                                                              : "Operations")
                .popover(isPresented: $model.showOperations, arrowEdge: .bottom) {
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
            Button("Refresh") { refresh() }
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
    /// Worn by the grid and by an open detail pane's content alike.
    func refreshVeil(_ active: Bool) -> some View {
        modifier(RefreshVeil(active: active))
    }

    /// The wash behind an inline warning — a deprecated package, an untrusted tap. Shared so the
    /// two banners cannot drift apart, and so the tint answers Increase Contrast in one place: a
    /// fixed 10% wash ignores the setting, and the system's own answer is a stronger fill plus the
    /// border it adds to controls.
    func warningWash(_ tint: Color) -> some View {
        modifier(WarningWash(tint: tint))
    }
}

struct WarningWash: ViewModifier {
    let tint: Color

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let increased = contrast == .increased
        return content
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(increased ? 0.22 : 0.1), in: shape)
            .overlay { if increased { shape.strokeBorder(tint.opacity(0.5)) } }
    }
}

/// A modifier rather than a plain extension so it can read Reduce Motion: animating into and out
/// of a blur, and sustaining a rotation, are two of the effects that setting exists to remove. The
/// dimming survives — it is the part that carries the meaning.
struct RefreshVeil: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .blur(radius: active && !reduceMotion ? 6 : 0)
            .opacity(active ? 0.5 : 1)
            .overlay {
                if active {
                    Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect()
                        .transition(reduceMotion ? AnyTransition.opacity
                                                : AnyTransition(.blurReplace))
                }
            }
            .animation(.smooth(duration: 0.3), value: active)
    }
}

/// The Safari-downloads pattern: everything this session did, newest first, each row unfolding
/// into its live log.
private struct OperationsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    // The "Running…" caption below already says this without moving.
                    .symbolEffect(.rotate, options: .repeating,
                                  isActive: operation.state == .running && !reduceMotion)

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
