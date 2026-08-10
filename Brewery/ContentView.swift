//
//  ContentView.swift
//  Brewery
//
//  Created by vzbarashchenko on 09.08.2026.
//

import SwiftUI

/// The three fixed destinations of the sidebar.
nonisolated enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case discover, installed, outdated

    var id: Self { self }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .installed: "Installed"
        case .outdated: "Outdated"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "sparkle.magnifyingglass"
        case .installed: "checkmark.circle"
        case .outdated: "arrow.triangle.2.circlepath"
        }
    }

    var searchPrompt: String {
        switch self {
        case .discover: "Search Homebrew"
        case .installed: "Search Installed"
        case .outdated: "Search Outdated"
        }
    }

    /// Shown by the grid when the section has nothing to list and no search is active.
    var emptyMessage: String? {
        switch self {
        case .discover: nil
        case .installed: "No packages installed"
        case .outdated: "Everything is up to date"
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

    @State private var selection: SidebarSection? = .discover
    @State private var results: [SearchHit] = []
    /// The browse listing, built once per change of the underlying array rather than per body pass.
    /// Rebuilding it inline cost two full walks of the 16k catalog every time the body ran — and,
    /// worse, handed SwiftUI a fresh array each time, so its cheap CoW identity check for "did this
    /// change?" degraded into a 16k element-by-element comparison.
    @State private var browseHits: [SearchHit] = []
    /// The section `results` were ranked over; a switch invalidates them until the task re-ranks.
    @State private var resultsSection: SidebarSection?
    @State private var selectedPackage: Package?
    @State private var showOperations = false
    @FocusState private var searchFocused: Bool

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
                        .badge(item == .outdated ? model.outdatedCount : 0)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .navigationTitle(section.title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    filterToolbar
                    operationsToolbar
                }
                .searchable(text: searchQuery, prompt: section.searchPrompt)
                .searchFocused($searchFocused)
        }
        .task(id: searchKey) {
            guard isSearching else {
                results = []
                resultsSection = nil
                return
            }
            // Debounce. The sleep throws when the next keystroke replaces this task — a bare
            // `try? await` would swallow that and let the stale ranking assign anyway.
            guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }
            results = await FuzzySearch.rank(query: searchText,
                                             in: sourcePackages,
                                             commands: model.commandIndex)
            resultsSection = section
        }
        .task(id: browseKey) {
            browseHits = sourcePackages.map { SearchHit(package: $0, matchedCommand: nil) }
        }
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
        } else {
            PackageGridView(hits: displayedHits,
                            isSearching: isSearching,
                            onSelect: { selectedPackage = $0 },
                            emptyMessage: emptyMessage,
                            resetToken: searchKey.window)
        }
    }

    // MARK: - Search

    private var section: SidebarSection { selection ?? .discover }

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

    private var sourcePackages: [Package] {
        switch section {
        case .discover: filtered(model.catalog)
        case .installed: model.installedPackages(scope: installedScope)
        case .outdated: model.outdatedPackages
        }
    }

    /// Discover's pre-filter. It runs before `FuzzySearch.rank`, so ranking only ever sees fewer
    /// candidates, and because it sits on the source array it governs browsing with no query too.
    private func filtered(_ packages: [Package]) -> [Package] {
        guard filtersActive else { return packages }
        return packages.filter { package in
            // A disabled package is further along the same lifecycle as a deprecated one, and
            // cannot be installed at all.
            kindFilter.matches(package) && !(hideDeprecated && (package.deprecated || package.disabled))
        }
    }

    private var filtersActive: Bool { kindFilter != .all || hideDeprecated }

    /// Discover has no empty state of its own — by the time it renders, the catalog is loaded — but
    /// a filter can empty it, and so can the On Request scope on a machine whose kegs are all deps.
    private var emptyMessage: String? {
        switch section {
        case .discover:
            filtersActive ? "No packages match the filters" : nil
        case .installed:
            installedScope == .onRequest && !model.installed.isEmpty
                ? "No packages installed on request"
                : section.emptyMessage
        case .outdated:
            section.emptyMessage
        }
    }

    /// An empty query bypasses ranking entirely, so the section array — already alphabetical —
    /// is rendered straight from the model and stays live as operations finish. Results from
    /// another section are equally unusable: during the debounce after a section switch the new
    /// section's own array stands in, never the old section's cards.
    private var displayedHits: [SearchHit] {
        guard isSearching, resultsSection == section else { return browseHits }
        return results
    }

    /// What the grid will render. Reads the cached array rather than rebuilding it to count it.
    private var displayedCount: Int {
        guard isSearching, resultsSection == section else { return browseHits.count }
        return results.count
    }

    /// What the browse listing is made of. Deliberately excludes the query: while a search is being
    /// typed the grid still shows this listing, so rebuilding it per keystroke would be pure waste.
    private struct BrowseKey: Equatable {
        let section: SidebarSection
        let kindFilter: KindFilter
        let hideDeprecated: Bool
        let installedScope: InstalledScope
        let catalogCount: Int
        let installedCount: Int
        let outdatedCount: Int
    }

    private var browseKey: BrowseKey {
        BrowseKey(section: section,
                  kindFilter: kindFilter,
                  hideDeprecated: hideDeprecated,
                  installedScope: installedScope,
                  catalogCount: model.catalog.count,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count)
    }

    private var searchKey: SearchKey {
        SearchKey(window: WindowToken(section: section,
                                      query: searchText,
                                      kindFilter: kindFilter,
                                      hideDeprecated: hideDeprecated,
                                      installedScope: installedScope),
                  catalogCount: model.catalog.count,
                  commandCount: model.commandIndex.count,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count)
    }

    /// Re-ranks on a new query, a section switch, a filter change, or any change to the arrays
    /// being searched.
    private struct SearchKey: Equatable {
        let window: WindowToken
        let catalogCount: Int
        /// The command index lands a beat after the catalog it is derived from; without this a
        /// query typed during launch would keep results that never saw the index.
        let commandCount: Int
        let installedCount: Int
        let outdatedCount: Int
    }

    /// The part of the key that changes *which* packages are listed — the grid restarts its render
    /// window on it. A refresh landing new versions deliberately does not.
    private struct WindowToken: Hashable {
        let section: SidebarSection
        let query: String
        let kindFilter: KindFilter
        let hideDeprecated: Bool
        let installedScope: InstalledScope
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
        }
    }

    /// Whether the section is showing something other than its plain default listing.
    private var isNarrowed: Bool {
        switch section {
        case .discover: filtersActive
        case .installed: installedScope != .onRequest
        case .outdated: false
        }
    }

    // MARK: - Filters

    /// Each section carries only its own control; Outdated has none.
    @ToolbarContentBuilder private var filterToolbar: some ToolbarContent {
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
                            Text(model.activeCount, format: .number)
                                .monospacedDigit()
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
