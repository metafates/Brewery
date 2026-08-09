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

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: SidebarSection? = .discover
    @State private var searchText = ""
    @State private var results: [Package] = []
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
                .toolbar { operationsToolbar }
                .searchable(text: $searchText, prompt: section.searchPrompt)
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
            results = await FuzzySearch.rank(query: searchText, in: sourcePackages)
            resultsSection = section
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
            PackageGridView(packages: displayedPackages,
                            isSearching: isSearching,
                            onSelect: { selectedPackage = $0 },
                            emptyMessage: section.emptyMessage)
        }
    }

    // MARK: - Search

    private var section: SidebarSection { selection ?? .discover }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sourcePackages: [Package] {
        switch section {
        case .discover: model.catalog
        case .installed: model.installedPackages
        case .outdated: model.outdatedPackages
        }
    }

    /// An empty query bypasses ranking entirely, so the section array — already alphabetical —
    /// is rendered straight from the model and stays live as operations finish. Results from
    /// another section are equally unusable: during the debounce after a section switch the new
    /// section's own array stands in, never the old section's cards.
    private var displayedPackages: [Package] {
        guard isSearching, resultsSection == section else { return sourcePackages }
        return results
    }

    private var searchKey: SearchKey {
        SearchKey(section: section,
                  query: searchText,
                  catalogCount: model.catalog.count,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count)
    }

    /// Re-ranks on a new query, a section switch, or any change to the arrays being searched.
    private struct SearchKey: Equatable {
        let section: SidebarSection
        let query: String
        let catalogCount: Int
        let installedCount: Int
        let outdatedCount: Int
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
