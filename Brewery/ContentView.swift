//
//  ContentView.swift
//  Brewery
//
//  Created by metafates on 09.08.2026.
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
        Text("Formulae are command-line tools for Terminal. Casks are regular Mac apps. Everything installs with one click — use the filter to browse one kind.")
    }

    var image: Image? {
        Image(systemName: "shippingbox")
    }
}

/// The fixed destinations of the sidebar: the library, then the reports. Orphans and
/// Attention are destinations, not Installed scopes — they carry their own headers, actions and
/// empty states, and a titled sidebar group is the platform's container for exactly that (HIG
/// *Sidebars*: succinct, descriptive labels title each group).
nonisolated enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case discover, installed, outdated, services, taps, orphans, attention, storage, checkup

    /// The sidebar's two groups, in row order.
    static let library: [SidebarSection] = [.discover, .installed, .outdated, .services, .taps]
    static let reports: [SidebarSection] = [.orphans, .attention, .storage, .checkup]

    var id: Self { self }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .installed: "Installed"
        case .outdated: "Outdated"
        case .services: "Services"
        case .taps: "Taps"
        case .orphans: "Orphans"
        case .attention: "Attention"
        case .storage: "Storage"
        case .checkup: "Checkup"
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
        // Each report wears its own summary bar's glyph — the row and the page say the same thing.
        case .orphans: "arrow.3.trianglepath"
        case .attention: "exclamationmark.triangle"
        // The detail pane's own "on disk" glyph — the row and the stat say the same thing.
        case .storage: "internaldrive"
        case .checkup: "stethoscope"
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
        case .orphans: "6"
        case .attention: "7"
        case .storage: "8"
        case .checkup: "9"
        }
    }

    var searchPrompt: String {
        switch self {
        case .discover: "Search Homebrew"
        case .installed: "Search Installed"
        case .outdated: "Search Outdated"
        case .services: "Search Services"
        case .taps: "Search Taps"
        case .orphans: "Search Orphans"
        case .attention: "Search Attention"
        case .storage: "Search Storage"
        case .checkup: "Search Findings"
        }
    }

    /// Shown by the grid when the section has nothing to list and no search is active.
    var emptyMessage: String? {
        switch self {
        case .discover: nil
        case .installed: "No Packages Installed"
        case .outdated: "Everything is up to date"
        // ServicesView owns its own empty state; the grid never renders this section.
        case .services: nil
        case .taps: "No Packages"
        case .orphans: "No Orphaned Dependencies"
        // Software Update's positive-empty grammar: the good outcome, stated plainly.
        case .attention: "Nothing needs attention"
        case .storage: "No Old Versions on Disk"
        // The view owns its own states — intro, running, clean, findings (Discover's rule).
        case .checkup: nil
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

/// The model's subsets of what is on disk: what the user asked for, everything, the
/// orphan report — dependencies nothing installed still needs — and the attention
/// report — packages Homebrew has deprecated or disabled. UI-wise this is no longer
/// one picker: Installed reaches onRequest/all through the Filter menu's Show Dependencies
/// toggle, and the reports are sidebar destinations.
nonisolated enum InstalledScope {
    case onRequest, all, orphans, attention, storage
}

/// Installed's sort orders, Finder's *Sort By* vocabulary. Name is the inventory default;
/// dates and sizes read newest- and largest-first, which is the question each answers ("what
/// did I just install", "what is costing me space"). Installed only: Discover browses by
/// popularity, and Outdated/Services are a dozen rows.
nonisolated enum InstalledSort: String, CaseIterable, Identifiable {
    case name, dateInstalled, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .dateInstalled: "Date Installed"
        case .size: "Size"
        }
    }

    /// View ▸ Sort By key equivalents, ⌃⌘1…3 — Finder's own sort-by modifier family, clear of
    /// the destinations' plain ⌘1…5.
    var shortcut: KeyEquivalent {
        switch self {
        case .name: "1"
        case .dateInstalled: "2"
        case .size: "3"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Every x-axis slide and sustained rotation below has a crossfade or a still glyph behind this.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("discover.kindFilter") private var kindFilter: KindFilter = .all
    @AppStorage("discover.hideDeprecated") private var hideDeprecated = false
    /// On Request is the default truth of Installed; dependency-only kegs join it through
    /// this Filter-menu toggle (each already wears the "dependency" mark). The old four-way
    /// scope picker is gone: its two report segments are sidebar destinations now.
    @AppStorage("installed.showDependencies") private var showDependencies = false
    /// A source is not a kind: a tap item IS a formula or cask, so "from taps" is a combinable
    /// toggle like Hide Deprecated, never a kind-picker case — "casks from taps" must be sayable.
    @AppStorage("discover.tapsOnly") private var tapsOnly = false
    /// Installed's own kind filter — deliberately separate state from Discover's: switching tabs
    /// must not carry one tab's filter into the other.
    @AppStorage("installed.kindFilter") private var installedKindFilter: KindFilter = .all
    @AppStorage("installed.tapsOnly") private var installedTapsOnly = false
    /// Pinned Only: the one place all pins are listable at once (user-requested).
    @AppStorage("installed.pinnedOnly") private var installedPinnedOnly = false
    /// Installed's sort. `@AppStorage`, not model state, for the same reason as the
    /// filters: it is a view preference, and the View ▸ Sort By commands share it by key.
    @AppStorage("installed.sort") private var installedSort: InstalledSort = .name

    /// Ranked results per section, so leaving a tab and coming back shows that tab's results at
    /// once. A single array meant visiting a tab with an empty query cleared it, and the return
    /// trip flashed the unfiltered listing until the re-rank landed.
    @State private var results: [SidebarSection: [SearchHit]] = [:]
    /// Browse listings per section — the same grammar as `results`, for the same reason. A single
    /// array meant every ⌘1…⌘5 rebuilt the listing from scratch on the main actor (for Discover, a
    /// filter + popularity sort + map over the 16k catalog — the tab-switch lag) and rendered the
    /// *previous* section's cards for a frame until the rebuild landed. Built in a task, never
    /// inline: rebuilding per body pass handed SwiftUI a fresh array each time, so its cheap CoW
    /// identity check degraded into a 16k element-by-element comparison.
    @State private var browseHits: [SidebarSection: [SearchHit]] = [:]
    /// The inputs each cached listing was built from, so revisiting a tab with nothing changed
    /// skips the rebuild outright instead of paying it on every switch.
    @State private var builtKeys: [SidebarSection: BrowseKey] = [:]
    @FocusState private var searchFocused: Bool
    @State private var kindsTip = PackageKindsTip()
    /// TipView hides itself once dismissed, but its row keeps its insets — a permanent empty
    /// band atop Discover (TapsView's own lesson). Gate the row on the tip's status.
    @State private var showKindsTip = false

    /// How many cards are handed to the grid. It grows as the end of the list is reached and resets
    /// whenever the listing changes. It lives here, not in the grid, because the slicing has to
    /// happen on *this* side of the view boundary — see the note on `PackageGridView`.
    private static let windowStep = 60
    @State private var window = ContentView.windowStep

    var body: some View {
        if model.brewMissing {
            Group {
                if model.isRefreshing {
                    // Check Again re-probes the brew paths; the claim is being recomputed, so
                    // the wait replaces it (the Checkup claim-replacement grammar). Keyed to
                    // isRefreshing, not isChecking: only refresh() re-runs discovery, and a
                    // background tick that cannot change the answer must not blink the claim.
                    WorkingCapsule(text: "Checking…")
                } else {
                    brewNotFound
                }
            }
            .animation(.smooth(duration: 0.3), value: model.isRefreshing)
        } else {
            splitView
        }
    }

    /// Opening a package means selecting it, not interrupting: the pane follows the selection, so
    /// clicking through card after card is one continuous act rather than open-read-dismiss.
    private func select(_ package: Package) {
        // Selection lives in the model: the menu bar's Uninstall command needs a target,
        // and the request counter lets the pane react to re-selecting the same package.
        model.select(package)
    }

    // MARK: - Shell

    /// The trust-consent dialog's title: the situation, succinctly (HIG Alerts).
    private var trustConsentTitle: Text {
        guard let package = model.pendingInstall,
              let tap = model.effectiveTap(for: package) else { return Text(verbatim: "") }
        return Text("Install \(package.title) from \(tap)?")
    }

    /// Remove Tap's title, the uninstall grammar: a question when removable, a statement when
    /// blocked.
    private var tapRemovalTitle: String {
        guard let info = model.pendingTapRemoval else { return "" }
        return model.installedCount(fromTap: info.name) > 0
            ? "\(info.name) is still in use"
            : "Remove \(info.name)?"
    }

    /// The uninstall dialog's title, same grammar — except blocked, where there is no
    /// question to ask: the dialog is informational (HIG Alerts), a statement with an OK.
    private var uninstallTitle: Text {
        guard let package = model.pendingUninstall else { return Text(verbatim: "") }
        if !model.blockingDependents(for: package).isEmpty {
            return Text("\(package.title) is still needed")
        }
        return Text("Uninstall \(package.title)?")
    }

    /// The consequence and the way back, per state: blocked names the dependents (Remove Tap's
    /// grammar); multi-keg formulae disclose the leftover — `--force` is unrepresentable, and a
    /// repeat uninstall peels it; the zap tier carries brew's shared-files warning
    /// (Cask-Cookbook.md:1312-1315).
    private func uninstallMessage(for package: Package) -> String {
        let blocking = model.blockingDependents(for: package)
        if !blocking.isEmpty {
            let names = AppModel.dependentsSummary(blocking)
            return "\(package.title) is required by \(names). Uninstall \(blocking.count == 1 ? "it" : "them") first."
        }
        var message = "Removes \(package.title) from your Mac. You can install it again later."
        let versions = model.installed[package.id]?.versions ?? []
        if package.kind == .formula, versions.count > 1, let current = versions.last {
            let older = versions.dropLast().formatted(.list(type: .and))
            message += " This removes version \(current); older versions (\(older)) stay on disk until you uninstall again."
        }
        if model.installed[package.id]?.hasZap == true {
            message += " “Uninstall and Remove App Data” also deletes its settings and support files; files shared with other apps may be removed."
        }
        return message
    }

    private var splitView: some View {
        @Bindable var model = model

        return NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarSection.library) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badgeCount(for: item))
                }
                // The reports, in the source list's own grammar (Mail's Smart Mailboxes,
                // Finder's groups): always discoverable, never floating over the listing.
                Section("Reports") {
                    ForEach(SidebarSection.reports) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(badgeCount(for: item))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    // Sections, not one glass run: the section-scoped tier (filter/sort/
                    // Update All), then the app-wide pair, then the inspector toggle on its
                    // own — the text-labelled action must not read as part of the icon
                    // cluster (HIG Toolbars: group related items).
                    filterToolbar
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    refreshToolbar
                    operationsToolbar
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    inspectorToolbar
                }
                .searchable(text: $model.query, prompt: searchPrompt)
                .searchFocused($searchFocused)
                // Return opens the top hit — the keyboard path from typing a name to reading about
                // it, without reaching for the pointer.
                .onSubmit(of: .search) {
                    // Only a landed ranking has a top hit; a browse listing's first card is
                    // arbitrary, and Return must not claim it as the best match.
                    guard isSearching, let hit = results[section]?.first else { return }
                    select(hit.package)
                }
                // A pane, not a sheet: the listing stays live beside it, it resizes with the
                // window, and nothing has to be dismissed before the next card can be clicked.
                .inspector(isPresented: $model.showInspector) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
                }
        }
        // Trust consent, at the moment of consequence: every Install surface funnels
        // through AppModel.install, and when the grant would be new the dialog asks instead.
        // The same confirmationDialog grammar the tap page's Trust and Remove decisions use.
        .confirmationDialog(trustConsentTitle,
                            isPresented: $model.trustConsentPresented,
                            titleVisibility: .visible,
                            presenting: model.pendingInstall) { package in
            Button("Install") { model.confirmedInstall(package) }
            Button("Trust Tap and Install") { model.confirmedInstall(package, trustingTap: true) }
            Button("Cancel", role: .cancel) {}
        } message: { package in
            Text("This tap isn't trusted yet. Installing trusts only \(package.name)'s recipe; trusting the tap covers everything it ships.")
        }
        // Uninstall consent: every Uninstall surface funnels through AppModel.uninstall,
        // and the dialog runs before anything enqueues (the trust-write rule). A formula
        // something still needs loses the destructive buttons and the message explains —
        // Remove Tap's exact shape. The zap tier appears only when the receipt earned it.
        .confirmationDialog(uninstallTitle,
                            isPresented: $model.uninstallConfirmationPresented,
                            titleVisibility: .visible,
                            presenting: model.pendingUninstall) { package in
            if model.blockingDependents(for: package).isEmpty {
                Button("Uninstall", role: .destructive) { model.confirmedUninstall(package) }
                if model.installed[package.id]?.hasZap == true {
                    Button("Uninstall and Remove App Data", role: .destructive) {
                        model.confirmedUninstall(package, zap: true)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                // A confirmation with no yes is a statement: acknowledge, don't "cancel"
                // nothing. The cancel role keeps Escape working.
                Button("OK", role: .cancel) {}
            }
        } message: { package in
            Text(uninstallMessage(for: package))
        }
        .confirmationDialog(tapRemovalTitle,
                            isPresented: $model.tapRemovalPresented,
                            titleVisibility: .visible,
                            presenting: model.pendingTapRemoval) { info in
            if model.installedCount(fromTap: info.name) == 0 {
                Button("Remove Tap", role: .destructive) { model.removeTap(info.name) }
                Button("Cancel", role: .cancel) {}
            } else {
                // Blocked removal is informational — a statement with an OK (the uninstall
                // dialog's rule); the cancel role keeps Escape working.
                Button("OK", role: .cancel) {}
            }
        } message: { info in
            if model.installedCount(fromTap: info.name) > 0 {
                Text("Homebrew refuses to remove a tap while packages from it are installed. Uninstall them first.")
            } else {
                Text("This removes the tap's local copy — you can add it back anytime. If the tap is trusted, it stays trusted when you re-add it.")
            }
        }
        .confirmationDialog(CleanupDialog.title,
                            isPresented: $model.confirmingCleanup, titleVisibility: .visible) {
            Button(CleanupDialog.confirm, role: .destructive) { model.cleanUp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CleanupDialog.message)
        }
        // Pluralized by hand: the ^[](inflect:) markdown renders fine in a bar's Text but
        // arrives raw in a dialog title, wrapped in Text or not.
        .confirmationDialog(
            model.orphanIDs.count == 1
                ? "Remove 1 orphaned dependency?"
                : "Remove \(model.orphanIDs.count) orphaned dependencies?",
            isPresented: $model.confirmingAutoremove, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { model.autoremove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // brew's autoremove selection is pin-blind: a pinned orphan is listed, then the
            // uninstall refusal skips it — exit 0. Disclose rather than desync the count.
            Text(model.orphanIDs.contains(where: { id in
                model.package(for: id).map(model.isPinned) == true
            })
            ? "These are dependencies nothing needs anymore. You can install any of them again later. Pinned packages will be skipped."
            : "These are dependencies nothing needs anymore. You can install any of them again later.")
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
            results[ranked] = await FuzzySearch.rank(query: model.query,
                                                     in: sourcePackages,
                                                     commands: model.commandIndex)
        }
        .task(id: browseKey) {
            // A revisit with nothing changed: the cached listing is already right.
            let key = browseKey
            guard builtKeys[key.listing.section] != key else { return }
            var packages = sourcePackages
            // Discover browses by popularity, not by name: an alphabetical walk of 16k packages
            // opens on "0 A.D." and never reaches anything anyone installs. Installed and Outdated
            // are inventories, where alphabetical is the order you scan.
            if section == .discover || (section == .taps && TapStore.coreTaps.contains(model.selectedTap ?? "")) {
                packages.sort(by: Package.popularityOrder)
            }
            // Installed's chosen order, every scope. Search results stay relevance-ranked
            // (Finder's own behavior), which is why this lives on the browse path only.
            if section == .installed {
                switch installedSort {
                case .name:
                    break   // the compose order is already the canonical alphabetical
                case .dateInstalled:
                    let dates = model.installed.compactMapValues(\.installedAt)
                    packages.sort { Package.installDateOrder($0, $1, dates: dates) }
                case .size:
                    let sizes = model.diskSizes
                    packages.sort { Package.sizeOrder($0, $1, sizes: sizes) }
                }
            }
            browseHits[key.listing.section] = packages.map { SearchHit(package: $0, matchedCommand: nil) }
            builtKeys[key.listing.section] = key
        }
        // The Size sort's data: sweep every installed package when the sort needs it, and
        // again when the installed set changes. A warm pass is instant and publishes nothing.
        .task(id: sizeSweepKey) {
            guard sizeSweepKey.active else { return }
            await model.measureSizes()
        }
        .onChange(of: searchKey.window) { window = Self.windowStep }
        .task {
            for await status in kindsTip.statusUpdates {
                showKindsTip = status == .available
            }
        }
        .onChange(of: model.findRequests) { searchFocused = true }
        // `initial: true`, and the Dock bounce lives in the model beside the flag: a failure
        // can land while no window exists, and a plain onChange would never see the value it
        // was set to while this view was unmounted.
        .onChange(of: model.failureToPresent?.id, initial: true) { _, failure in
            guard failure != nil else { return }
            model.showOperations = true
            model.failureToPresent = nil
        }
    }

    @ViewBuilder private var detail: some View {
        // The catalog gates Discover only: Installed and Outdated stand on their own, synthesizing
        // packages for anything the catalog does not cover.
        if section == .discover, model.catalog.isEmpty, model.catalogFailed {
            catalogFailed
        } else if section == .discover, model.catalog.isEmpty {
            WorkingCapsule(text: "Loading catalog…")
        } else if section == .taps {
            // In-column drill-down, no transition: macOS NavigationStack does not animate
            // this push — a split view's detail column swaps instantly, as do Finder's and
            // Mail's own drill-ins — so the hand-rolled slide was imitating motion the platform
            // doesn't perform here, and a translucent grid crossing a fading list read as smear,
            // not navigation (HIG Motion: add motion purposefully; avoid adding motion to
            // frequent interactions). Still a ZStack rather than if/else: the list stays
            // mounted, keeping its scroll position for the way back.
            ZStack {
                TapsView(searchText: model.query, isChecking: model.isChecking, onSelect: openTap)
                    .opacity(model.selectedTap == nil ? 1 : 0)
                    // Disabled, not just covered: the hidden rows must leave the Tab order.
                    .disabled(model.selectedTap != nil)
                    .accessibilityHidden(model.selectedTap != nil)
                if let tap = model.selectedTap {
                    packageGrid(tap: tap)
                        // Opaque, so the mounted list never shows through between the cards.
                        .background(.background)
                }
            }
        } else if section == .services {
            // State rows, not catalog cards — a handful of items, no windowing needed.
            ServicesView(hits: displayedHits,
                         isSearching: isSearching,
                         isChecking: model.isChecking,
                         selectedID: inspectedID,
                         onSelect: { select($0) },
                         onRefresh: { refresh() })
        } else if section == .checkup {
            // Findings, not packages — the view owns its states, including its own wait.
            CheckupView(searchText: model.query)
        } else if section == .orphans || section == .attention || section == .storage {
            // Reports are state rows, not catalog cards (the Services rule generalized).
            ReportListView(hits: displayedHits,
                           isSearching: isSearching,
                           isChecking: model.isChecking,
                           selectedID: inspectedID,
                           onSelect: { select($0) },
                           onRefresh: { refresh() },
                           emptyMessage: emptyState?.message,
                           kind: section == .orphans ? .orphans
                               : section == .attention ? .attention : .storage) {
                if section == .orphans {
                    OrphanSummaryBar()
                } else if section == .attention {
                    AttentionSummaryBar()
                } else {
                    StorageSummaryBar()
                }
            }
        } else {
            packageGrid()
        }
    }

    /// `.id` on the package: the pane keeps a drill-down stack, and clicking a different card has
    /// to start a fresh one rather than leave you inside the previous package's dependencies.
    @ViewBuilder private var inspector: some View {
        if let package = model.selectedPackage {
            // The pane's back yields ⌘[ while a tap page shows its own — one shortcut, one owner.
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
                        emptyMessage: emptyState?.message,
                        emptySymbol: section.symbol,
                        onNeedMore: { window += Self.windowStep },
                        onRefresh: emptyState?.isFiltered == true ? nil : emptyStateRefresh,
                        // One signal for every empty slot: while any state work runs, an
                        // empty listing shows the wait instead of a claim mid-recompute.
                        isChecking: model.isChecking,
                        onClearFilters: emptyState?.isFiltered == true ? { clearFilters() } : nil,
                        header: {
                            if let tap {
                                TapPageHeader(tap: tap)
                            } else if section == .outdated {
                                freshnessCaption
                            } else if section == .installed {
                                sizeMeasuringCaption
                            } else {
                                discoverTip
                            }
                        })
        // The grid's identity is the listing's identity. Discover, Installed, Outdated and
        // every tap page render through this one call, so without it they share a ScrollView
        // and its scroll offset survives the switch: leaving Discover at 7228 pt landed in
        // Installed at 7228 (or clamped to its bottom), which also parks the window sentinel
        // on screen and immediately grows the render window to 120. `ListingToken` is exactly
        // the set of inputs that change *which* packages are listed, and it is already what
        // resets the render window — so the scroller and the window restart together.
        // The query stays out, deliberately: a per-keystroke teardown would attack the
        // pinned 0.5 s keystroke budget, and `catalogGeneration` stays out for the reason
        // already recorded — a recompose must never reset the scroll window.
        .id(listingToken)
    }

    /// The Outdated page's status feedback, integrated into the page rather than raised at
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
                // Ticks every second so the caption turns over the moment its unit does; the
                // *string* stays minute-granular ("just now", then "1 minute ago"), so the text
                // only redraws when the unit flips and the caption stays calm (HIG Progress
                // indicators: keep indicators moving so people know something is continuing to
                // happen). Not `.everyMinute`: its ticks are wall-clock minute boundaries, not
                // anchored to `checked` — the unit flip landed up to a minute late, and on macOS
                // the schedule proved unreliable outright ("does not update in real time").
                // The string must be computed *from context.date*: a Text whose stored inputs
                // never change diffs as unchanged, so the schedule alone redraws nothing.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.lastCheckedCaption(checked: checked, now: context.date))
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// Under a minute it is "just now" — Finder's word for it: at minute granularity a seconds
    /// figure would sit frozen mid-count. The guard also clamps a tick that lands before the
    /// stat (schedule alignment, clock skew), which otherwise phrases the past as the future
    /// ("in 30 seconds"). Static and pure so the bucketing has a test.
    static func lastCheckedCaption(checked: Date, now: Date) -> String {
        guard now.timeIntervalSince(checked) >= 60 else { return "Last checked just now" }
        return "Last checked \(checkedFormatter.localizedString(for: checked, relativeTo: now))"
    }

    /// "5 minutes ago", "2 hours ago", "yesterday" — anchored to the timeline tick, not to format
    /// time. Locale pinned because every other string in the app is unlocalized English.
    private static let checkedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// The listing is built synchronously *before* the page swaps in: the browse task rebuilds
    /// it asynchronously, and a page that lands empty and fills a beat later reads as a bug.
    private func openTap(_ tap: String) {
        browseHits[.taps] = browseListing(for: tap)
        model.selectedTap = tap
        // Computed after the assignment, so the key names the new tap: what was just built is
        // exactly what the browse task would rebuild — record it so the task skips.
        builtKeys[.taps] = browseKey
    }

    /// The cold size sweep, named while it runs (HIG *Progress indicators*: a spinner for
    /// a background operation, description where helpful) — the Outdated freshness caption's
    /// grammar. A warm sweep finishes before anyone reads this, so it never flashes.
    @ViewBuilder private var sizeMeasuringCaption: some View {
        if installedSort == .size, model.isMeasuringSizes {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Measuring sizes…")
            }
            .accessibilityElement(children: .combine)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    /// Discover only, and only while browsing: the tip is a newcomer's explainer, not search
    /// feedback — and a TipView sharing the tree with `ContentUnavailableView.search` blanks
    /// the split view's sidebar (framework interaction, reproduced and pinned by UI test).
    @ViewBuilder private var discoverTip: some View {
        if section == .discover, !isSearching, showKindsTip {
            TipView(kindsTip)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        }
    }

    // MARK: - Search

    private var section: SidebarSection { model.selection ?? .discover }

    /// The Size sort's sweep trigger: active only where the sort is visible, re-keyed by the
    /// installed count so a new keg gets measured.
    private struct SizeSweepKey: Equatable {
        let active: Bool
        let installedCount: Int
    }

    private var sizeSweepKey: SizeSweepKey {
        SizeSweepKey(active: section == .installed && installedSort == .size,
                     installedCount: model.installed.count)
    }

    /// The tap page's listing, same as the browse task would build it — cheap enough for a click
    /// even on core (one filter, one ~8k sort).
    private func browseListing(for tap: String) -> [SearchHit] {
        var packages = tapPagePackages(for: tap)
        if TapStore.coreTaps.contains(tap) { packages.sort(by: Package.popularityOrder) }
        return packages.map { SearchHit(package: $0, matchedCommand: nil) }
    }

    /// A tap page titles the window with its tap's name.
    private var title: String {
        if section == .taps, let tap = model.selectedTap { return tap }
        return section.title
    }

    /// On a tap page the search field searches that tap's packages, not the tap list.
    private var searchPrompt: String {
        if section == .taps, model.selectedTap != nil { return "Search Packages" }
        return section.searchPrompt
    }

    /// Per-tab, and in the model rather than in `@State`: switching sections destroys the detail
    /// view along with anything it holds, so a query stored here would not survive the round trip.

    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        case .installed: installedFiltered(model.installedPackages(scope: showDependencies ? .all : .onRequest))
        case .outdated: model.outdatedPackages
        case .services: model.servicePackages
        case .taps: tapPagePackages(for: model.selectedTap)
        case .orphans: model.installedPackages(scope: .orphans)
        case .attention: model.installedPackages(scope: .attention)
        case .storage: model.installedPackages(scope: .storage)
        case .checkup: []
        }
    }

    /// A tap page's contents — the model's one membership rule, this page's kind filter
    /// on top. The list view (tap == nil) needs no packages.
    private func tapPagePackages(for tap: String?) -> [Package] {
        guard let tap else { return [] }
        let packages = model.packages(inTap: tap)
        guard model.tapKindFilter != .all else { return packages }
        return packages.filter(model.tapKindFilter.matches)
    }

    /// Installed's kind pre-filter — same position in the pipeline as Discover's: before ranking,
    /// and governing empty-query browsing too. A few hundred items, so no caching needed.
    private func installedFiltered(_ packages: [Package]) -> [Package] {
        guard installedKindFilter != .all || installedTapsOnly || installedPinnedOnly else { return packages }
        return packages.filter { package in
            // The effective tap, not `package.tap`: an installed tap item whose name collides
            // with core joins the core catalog entry, but its receipt knows the truth.
            installedKindFilter.matches(package)
                && !(installedTapsOnly && model.effectiveTap(for: package) == nil)
                && !(installedPinnedOnly && !model.isPinned(package))
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
    /// a filter can empty it, and so can On Request on a machine whose kegs are all deps.
    /// The cause rides along: a filter-emptied listing offers Clear Filters — Check Again
    /// cannot fix it — and a genuinely empty one offers the re-check.
    private var emptyState: (message: String, isFiltered: Bool)? {
        switch section {
        case .discover:
            filtersActive ? ("No packages match the filters", true) : nil
        case .installed:
            if installedKindFilter != .all || installedTapsOnly || installedPinnedOnly,
               !model.installed.isEmpty {
                ("No installed packages match the filters", true)
            } else if !showDependencies, !model.installed.isEmpty {
                ("No packages installed on request", true)
            } else {
                section.emptyMessage.map { ($0, false) }
            }
        case .outdated, .services, .orphans, .attention, .storage, .checkup:
            section.emptyMessage.map { ($0, false) }
        case .taps:
            model.tapKindFilter != .all ? ("No packages match the filter", true)
                                  : section.emptyMessage.map { ($0, false) }
        }
    }

    /// The section's own keys only — Clear Filters must not reach across tabs.
    private func clearFilters() {
        switch section {
        case .discover:
            (kindFilter, hideDeprecated, tapsOnly) = (.all, false, false)
        case .installed:
            (installedKindFilter, installedTapsOnly, installedPinnedOnly, showDependencies)
                = (.all, false, false, true)
        case .taps:
            model.tapKindFilter = .all
        default:
            break
        }
    }

    /// An empty query bypasses ranking entirely, so the section array — already alphabetical —
    /// is rendered straight from the model and stays live as operations finish. Results from
    /// another section are equally unusable: during the debounce after a section switch the new
    /// section's own array stands in, never the old section's cards.
    private var displayedHits: [SearchHit] {
        guard isSearching else { return browseHits[section] ?? [] }
        // Falling back to the listing only happens the very first time a section is searched,
        // before its first ranking lands.
        return results[section] ?? browseHits[section] ?? []
    }

    /// What the grid will render.
    private var displayedCount: Int { displayedHits.count }

    /// Which row the pane is describing, so the listing can say so. A split view has to keep the
    /// current selection visible in the pane that leads to the detail — and nil while the pane is
    /// closed, because nothing is being described. One `String?` across the boundary, not an array.
    private var inspectedID: Package.ID? {
        model.showInspector ? model.selectedPackage?.id : nil
    }

    /// What the browse listing is made of. Deliberately excludes the query: while a search is being
    /// typed the grid still shows this listing, so rebuilding it per keystroke would be pure waste.
    private struct BrowseKey: Equatable {
        let listing: ListingToken
        /// Not a count: a tap rescan can swap entries while netting zero, which a count cannot see.
        let catalogGeneration: Int
        let installedCount: Int
        let outdatedCount: Int
        let servicesCount: Int
        /// The size sweep's publish signal — a finished sweep re-sorts the listing it ordered.
        let sizesGeneration: Int
        /// Cleanup removes kegs without changing the package count; the Storage listing
        /// re-lists on this instead.
        let multiKegCount: Int
    }

    private var browseKey: BrowseKey {
        BrowseKey(listing: listingToken,
                  catalogGeneration: model.catalogGeneration,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count,
                  servicesCount: model.serviceStatuses.count,
                  sizesGeneration: model.sizesGeneration,
                  multiKegCount: model.multiKegCount)
    }

    private var searchKey: SearchKey {
        SearchKey(window: WindowToken(listing: listingToken, query: model.query),
                  catalogGeneration: model.catalogGeneration,
                  commandCount: model.commandIndex.count,
                  installedCount: model.installed.count,
                  outdatedCount: model.outdated.count,
                  servicesCount: model.serviceStatuses.count,
                  multiKegCount: model.multiKegCount)
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
        let multiKegCount: Int
    }

    /// The part of the key that changes *which* packages are listed — the grid restarts its
    /// render window on it. A refresh landing new versions deliberately does not, and
    /// `catalogGeneration` stays out: a recompose must never reset the scroll window.
    private struct WindowToken: Hashable {
        let listing: ListingToken
        let query: String
    }

    /// The ten values that decide which packages a section lists — navigation plus every
    /// filter, spelled once. BrowseKey and WindowToken both ride it; the generations and
    /// counts that *re-rank* without changing the question live beside it, never inside.
    private struct ListingToken: Hashable {
        let section: SidebarSection
        let kindFilter: KindFilter
        let hideDeprecated: Bool
        let showDependencies: Bool
        let installedKindFilter: KindFilter
        let tapsOnly: Bool
        let installedTapsOnly: Bool
        let installedPinnedOnly: Bool
        /// A sort change reorders which cards come first, so the window restarts like a filter's.
        let installedSort: InstalledSort
        let selectedTap: String?
        let tapKindFilter: KindFilter
    }

    private var listingToken: ListingToken {
        ListingToken(section: section,
                     kindFilter: kindFilter,
                     hideDeprecated: hideDeprecated,
                     showDependencies: showDependencies,
                     installedKindFilter: installedKindFilter,
                     tapsOnly: tapsOnly,
                     installedTapsOnly: installedTapsOnly,
                     installedPinnedOnly: installedPinnedOnly,
                     installedSort: installedSort,
                     selectedTap: model.selectedTap,
                     tapKindFilter: model.tapKindFilter)
    }

    // MARK: - Counts

    /// `.navigationSubtitle` is where macOS puts a count (Mail's message counts live there). It
    /// reports what the grid actually renders, so a search or a filter narrows it too.
    private var subtitle: String {
        guard section != .discover || !model.catalog.isEmpty else { return "" }

        // Checkup counts findings, not packages — and its search filters finding boxes, so
        // the generic "n results" (which counts packages) would lie. Before the search guard.
        if section == .checkup {
            if case .report(let report) = model.checkupOutcome, !report.findings.isEmpty {
                let count = report.findings.count
                return count == 1 ? "1 finding" : "\(count) findings"
            }
            return ""
        }

        // The tap list renders tap rows, not packages — count what TapsView actually shows,
        // before the search guard, or searching taps reports "0 results" of packages while
        // matching rows sit on screen (the Checkup rule).
        if section == .taps, model.selectedTap == nil {
            let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                let taps = model.tapInfos.count + 2   // + the two built-in rows
                return "\(taps) taps"
            }
            let lowered = query.lowercased()
            let matches = model.tapInfos.count { $0.name.lowercased().contains(lowered) }
                + ["homebrew/core", "homebrew/cask"].count { $0.contains(lowered) }
            return "\(matches == 1 ? "1 result" : "\(matches) results") for “\(query)”"
        }

        let count = displayedCount
        let formatted = count.formatted(.number)
        guard !isSearching, !isNarrowed else {
            // The ranker stops at its cap; claiming the cap as the true total would lie.
            let results = count == FuzzySearch.resultLimit ? "Top \(formatted) results"
                        : count == 1 ? "1 result" : "\(formatted) results"
            let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            // Finder's grammar (Searching “This Mac”): the count names its query, in curly
            // quotes. A filter-only narrowing has no query to name.
            return isSearching ? "\(results) for “\(query)”" : results
        }
        switch section {
        case .discover: return count == 1 ? "1 package" : "\(formatted) packages"
        case .installed: return "\(formatted) installed"
        case .outdated: return "\(formatted) outdated"
        case .services: return count == 1 ? "1 service" : "\(formatted) services"
        case .taps:
            // The list is handled above; reaching here means a tap page's grid.
            return count == 1 ? "1 package" : "\(formatted) packages"
        case .orphans: return count == 1 ? "1 orphan" : "\(formatted) orphans"
        case .attention: return count == 1 ? "1 needs attention" : "\(formatted) need attention"
        case .storage: return count == 1 ? "1 with old versions" : "\(formatted) with old versions"
        case .checkup: return ""   // handled above; unreachable
        }
    }

    /// Whether the section is showing something other than its plain default listing. Showing
    /// dependencies deliberately doesn't count: it widens toward the full truth of the disk,
    /// and "n results" for an unqueried listing would read as a search.
    private var isNarrowed: Bool {
        switch section {
        case .discover: filtersActive
        case .installed: installedKindFilter != .all || installedTapsOnly || installedPinnedOnly
        case .outdated, .services, .orphans, .attention, .storage, .checkup: false
        case .taps: model.selectedTap != nil && model.tapKindFilter != .all
        }
    }

    // MARK: - Filters

    /// Each section carries only its own control. Outdated's is the bulk action itself: the menu
    /// bar's ⇧⌘U is invisible from here, and the section whose whole job is updating should not
    /// make the user update one card at a time.
    @ToolbarContentBuilder private var filterToolbar: some ToolbarContent {
        if section == .taps {
            if model.selectedTap != nil {
                // In-column drill-down: back belongs in the navigation slot.
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.selectedTap = nil
                    } label: {
                        Label("Taps", systemImage: "chevron.backward")
                    }
                    .help("Back to the tap list")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        kindPicker(Bindable(model).tapKindFilter)
                    } label: {
                        filterLabel(active: model.tapKindFilter != .all)
                    }
                    .help("Filter by kind")
                    .accessibilityLabel("Filter")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.showAddTap = true
                    } label: {
                        Label("Add Tap", systemImage: "plus")
                    }
                    .help("Add a package catalog from GitHub")
                    .accessibilityLabel("Add Tap")
                    .popover(isPresented: Bindable(model).showAddTap, arrowEdge: .bottom) {
                        AddTapPopover(onAdd: { model.addTap($0) })
                    }
                }
            }
        }
        if section == .outdated, !model.outdated.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Update All") { model.upgradeAll() }
                    .disabled(model.upgradeAllPending)
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
                .help("Filter by kind, hide deprecated packages, or show only tap packages")
                .accessibilityLabel("Filter")
            }
        }
        // Filter and Sort share one group: both shape how the listing reads, and one
        // capsule instead of two thins the edge that used to overflow (HIG *Toolbars*: "group
        // toolbar items logically by function… minimize the number of groups").
        if section == .installed {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    kindPicker($installedKindFilter)
                    // Dependency visibility is a filter, so it lives with the filters;
                    // the filled funnel counts it because the listing differs from the default.
                    Toggle("Show Dependencies", isOn: $showDependencies)
                    Toggle("From Taps Only", isOn: $installedTapsOnly)
                    Toggle("Pinned Only", isOn: $installedPinnedOnly)
                } label: {
                    filterLabel(active: installedKindFilter != .all || installedTapsOnly
                                || installedPinnedOnly || showDependencies)
                }
                .help("Filter by kind, source or pin state, or show dependency-only packages")
                .accessibilityLabel("Filter")
                // The sort, in the Filter menu's own grammar (HIG *Pop-up buttons*: a flat
                // list of mutually exclusive options). Its menu-bar twin is View ▸ Sort By.
                Menu {
                    Picker("Sort By", selection: $installedSort) {
                        ForEach(InstalledSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort by name, date installed, or size")
                .accessibilityLabel("Sort")
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

    /// The same work ⌘R does, with somewhere to look while it happens. The glyph is the app's
    /// one chrome work tell: it turns for as long as *any* state work runs (`isChecking` — ⌘R,
    /// the inline update, the catalog download, a post-mutation reconcile), while the button
    /// disables only for the re-entrant case, a real ⌘R in flight.
    @ToolbarContentBuilder private var refreshToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // A Label, not a bare Image: the system overflow menu renders a toolbar item's
            // text, and an icon-only item there is a glyph with no name.
            Button { refresh() } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating,
                                      isActive: model.isChecking && !reduceMotion)
                }
            }
            .disabled(model.isRefreshing)
            .help("Refresh installed packages and check for updates")
        }
    }

    private func refresh() {
        Task { await model.refresh() }
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
                // Names the state it will produce, like its View-menu twin.
                Label(model.showInspector ? "Hide Info" : "Show Info",
                      systemImage: "sidebar.right")
            }
            .keyboardShortcut("i")
            .help(model.showInspector ? "Hide the info pane" : "Show the info pane")
        }
    }

    @ToolbarContentBuilder private var operationsToolbar: some ToolbarContent {
        @Bindable var model = model

        if !model.operations.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showOperations.toggle()
                } label: {
                    Group {
                        if model.isQueueActive {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.small)
                                // Rolls between values, so a queue draining reads as a count going
                                // down rather than as unrelated numbers replacing each other.
                                Text(model.activeCount, format: .number)
                                    .monospacedDigit()
                                    .contentTransition(reduceMotion ? .identity
                                                                     : .numericText(value: Double(model.activeCount)))
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
                    // Bare images and stacks, never `Label`: the toolbar bridge adopts a
                    // Label's *title* as the item's accessibility label, outranking every
                    // accessibility modifier — the failed state read as a plain "Operations"
                    // with the tell living only in the pointer-only tooltip (caught by
                    // HarnessTests.testFailedInstallPresentsTheFailure). With label-less
                    // content the bridge falls back to the modifiers below; `.ignore` also
                    // keeps a bare ProgressView from hoisting itself out as an
                    // ActivityIndicator and vanishing the button from the tree.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(operationsLabel)
                }
                .help(model.lastOperationFailed ? "Operations — the last one failed"
                                                : "Show the queue of Homebrew operations")
                .popover(isPresented: $model.showOperations, arrowEdge: .bottom) {
                    OperationsPopover()
                }
            }
        }
    }

    /// What the glyph shows, said aloud: the running count while active, the failure tell after.
    private var operationsLabel: String {
        if model.isQueueActive { return "Operations, \(model.activeCount) running" }
        if model.lastOperationFailed { return "Operations, last operation failed" }
        return "Operations"
    }

    // MARK: - Unavailable states

    private var brewNotFound: some View {
        ContentUnavailableView {
            Label("Homebrew Not Found", systemImage: "shippingbox")
        } description: {
            Text("Brewery needs Homebrew's brew command-line tool. Install Homebrew, then refresh.")
        } actions: {
            Link("Install Homebrew", destination: URL(string: "https://brew.sh")!)
                .buttonStyle(.borderedProminent)
            // The re-scan verb, app-wide.
            Button("Check Again") { refresh() }
        }
    }

    private var catalogFailed: some View {
        ContentUnavailableView {
            Label("Couldn't Load Catalog", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("Brewery downloads the Homebrew package list from formulae.brew.sh. Check your connection and try again.")
        } actions: {
            // The retry-after-failure verb, app-wide.
            Button("Try Again") {
                Task { await model.retryCatalog() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
