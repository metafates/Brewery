//
//  MaintenanceView.swift
//  Brewery
//

import SwiftUI

/// The two maintenance concerns whose **rows carry a decision**. Adopting is a per-app claim
/// about which cask owns which bundle; a retired package's *why* differs per package. The
/// other two — old versions, leftovers — are bulk: one command, one button, no per-row choice,
/// so they are cards above and have no rows at all.
private enum MaintenanceList: String {
    case unmanagedApps, retired

    var title: String {
        switch self {
        case .unmanagedApps: "Apps Homebrew could manage"
        case .retired: "No longer maintained"
        }
    }

    /// The sentence the deleted summary bars carried. It used to live in an empty state nobody
    /// ever saw; it belongs under the heading, where it explains the rows you are looking at.
    var explainer: String {
        switch self {
        case .unmanagedApps: "You installed these yourself. Let Homebrew keep them up to date."
        case .retired: "Homebrew has stopped updating these. Open one to see what to use instead."
        }
    }

    func count(_ value: Int) -> String {
        switch self {
        case .unmanagedApps: value == 1 ? "1 app" : "\(value) apps"
        case .retired: value == 1 ? "1 package" : "\(value) packages"
        }
    }
}

/// The maintenance surface: one page answering *what should I do about my Homebrew?*
///
/// **Cards for chores, rows for decisions.** This replaced four `DisclosureGroup` bands, which
/// were wrong twice over. Mechanically: on macOS a `DisclosureGroup`'s label does not toggle,
/// so the only hit target was the triangle — HIG *Outline views*, "make it easy for people to
/// expand or collapse nested containers". Structurally: membership across the bands *overlaps*
/// (a formula can keep old versions and be an orphan), and overlapping sets are not a tree —
/// HIG *Outline views*, "use a table instead of an outline view to present data that's not
/// hierarchical". No disclosure control survives here, so the hit target cannot regress again.
///
/// The two bulk bands also listed rows nobody could act on: `brew cleanup` and `brew autoremove`
/// are single commands, so ten rows each saying "1 old version" were ten rows of scrolling
/// between the reader and the one button. They are cards now, in the shape of System Settings ›
/// Storage (a gauge, then a recommendation with one sentence and one button) — the same
/// grammar `StorageSummaryBar` already cited. HIG *Designing for macOS* asks for "fewer nested
/// levels… while maintaining a comfortable information density that doesn't make people strain
/// to view the content they want"; the second half is the half this page was failing.
///
/// Checkup stays its own destination on a real axis: everything here is computed from data the
/// app already holds and is always current, while a checkup needs a subprocess and is run on
/// demand — which is also why it owns four states this page has no use for.
struct MaintenanceView: View {
    /// The union of the two listed concerns, ranked when a search is active. One array across
    /// the boundary, deduped upstream — the sections filter it rather than each taking their own.
    let hits: [SearchHit]
    let isSearching: Bool
    /// While any state work runs, an empty page shows the working capsule instead of claiming
    /// nothing needs doing — a claim is replaced, never contradicted, while it is recomputed.
    var isChecking = false
    var selectedID: Package.ID?
    let onSelect: (Package) -> Void
    let onRefresh: () -> Void

    @Environment(AppModel.self) private var model

    /// Rows shown before a section offers Show All. Five keeps both headings and both cards
    /// reachable without scrolling on the 780 pt default window, which is the whole point of
    /// the cap: the page has to answer "does anything need doing?" before anyone scrolls.
    private static let rowCap = 5

    /// Per-launch, not `@AppStorage`: this is App Store's Show More, not an outline's expansion
    /// state — HIG asks you to retain the latter, and the collapsed default here is the summary.
    @State private var showAllApps = false
    @State private var showAllRetired = false

    /// What `brew autoremove` would free — the whole rack per orphan, because that is what the
    /// command reclaims. Summed for the card; there are no rows to attribute it to.
    @State private var leftoverBytes: Int64?
    /// The cleanup total, published up from the card that already measures it. The page needs
    /// it for one boolean — "is the good news honest?" — and a second walk would re-measure
    /// every keg to learn something the first walk knew.
    @State private var cleanupBytes: Int64?

    var body: some View {
        let apps = listed(.unmanagedApps)
        let retired = listed(.retired)

        return List(selection: selection) {
            // Page state, not results: while searching, the page is its matches.
            if !isSearching {
                // Ordinary row slots, so the list's own insets are the shared gutter and the
                // cards' edges agree with the rows' content by construction.
                card { StorageSummaryBar(onMeasure: { cleanupBytes = $0 }) }
                if !model.orphanIDs.isEmpty {
                    card { LeftoversCard(bytes: leftoverBytes) }
                }
            }

            section(.unmanagedApps, hits: apps, showAll: $showAllApps)
            section(.retired, hits: retired, showAll: $showAllRetired)
        }
        .listStyle(.inset)
        .overlay {
            if apps.isEmpty, retired.isEmpty, isSearching || nothingToDo {
                emptyState
                    .animation(.smooth(duration: 0.3), value: isChecking)
            }
        }
        .task(id: measureKey) { await measure() }
    }

    /// Everything the page can act on is either measured at zero or absent. The cleanup total
    /// is part of it deliberately: a stale download cache is still something Clean Up… frees,
    /// and covering that card with "Everything looks good" would be a claim the card contradicts.
    private var nothingToDo: Bool {
        model.orphanIDs.isEmpty && (cleanupBytes ?? 0) == 0
    }

    // MARK: - Cards

    /// The card row slot: no separator, no selection, no list background — the box is the chrome.
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.bottom, 14)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }

    // MARK: - Sections

    /// The two sections are **disjoint**, and that is a rule, not an accident. Alacritty is
    /// both an unmanaged app and a deprecated cask, and listing it twice put one row under
    /// "let Homebrew keep them up to date" and another under "Homebrew has stopped updating
    /// these" — the same app, opposite advice. Retirement only describes a copy Homebrew is
    /// actually on the release train for, so an app installed by hand stays in the section
    /// that owns the decision, with the caveat on its own row.
    private func listed(_ kind: MaintenanceList) -> [SearchHit] {
        switch kind {
        case .unmanagedApps:
            // One row per *app*, not per candidate cask — 8 of 33 matches on a real machine
            // are ambiguous (charles/charles@4, transmission/@beta/@nightly). The narrowing to
            // the bundle's lead token belongs to `maintenancePackages`, which is also what the
            // toolbar counts and what search ranks: filtering it a second time here is how the
            // page listed twelve rows under a subtitle that said thirteen items.
            hits.filter { model.unmanaged[$0.package.id] != nil }
        case .retired:
            hits.filter { $0.package.needsAttention && model.unmanaged[$0.package.id] == nil }
        }
    }

    @ViewBuilder
    private func section(_ kind: MaintenanceList,
                         hits sectionHits: [SearchHit],
                         showAll: Binding<Bool>) -> some View {
        if !sectionHits.isEmpty {
            // A search already narrows the set; capping on top of it would hide matches the
            // result count claims to have found.
            let capped = isSearching || showAll.wrappedValue
                ? sectionHits : Array(sectionHits.prefix(Self.rowCap))
            Section {
                ForEach(capped.map { RowItem(kind: kind, package: $0.package) }) { item in
                    // The tag stays the bare `Package.ID`: a selection names *the package the
                    // pane is describing*, which the qualified row identity must not change.
                    MaintenanceRow(package: item.package, kind: kind)
                        .tag(item.package.id)
                }
                if capped.count < sectionHits.count {
                    showAllRow(sectionHits.count) { showAll.wrappedValue = true }
                }
            } header: {
                header(kind, count: sectionHits.count)
            }
        }
    }

    /// Name, count, and the sentence that says what these are. Not a shouted label: the
    /// heading is prose, which uppercasing destroys — and it carries the header trait, so
    /// VO-Command-H reaches it (`SectionTitle`'s rule, applied to a `Section` header).
    private func header(_ kind: MaintenanceList, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(kind.title)
                Text(kind.count(count))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .font(.subheadline)

            Text(kind.explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// App Store's Show More, and the direct answer to what the disclosure triangle got wrong:
    /// the hit target is the label's full width, shaped inside the button where it counts
    /// (a `.contentShape` outside a `Button` does not extend it) — `PaneRow`'s rule.
    private func showAllRow(_ count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Show All \(count)")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    // MARK: - Selection

    /// The system draws the highlight; selecting routes through the app's one selection funnel.
    /// Deselection (⎋) is ignored — the inspector, not the list, owns "nothing is selected".
    private var selection: Binding<Package.ID?> {
        Binding(get: { selectedID },
                set: { id in
                    guard let id, let hit = hits.first(where: { $0.package.id == id }) else { return }
                    onSelect(hit.package)
                })
    }

    // MARK: - Measurement

    /// Re-measure when the orphan set changes or a cleanup finishes — the byte total under an
    /// unchanged set is exactly what those two events move.
    private var measureKey: String {
        model.orphanIDs.sorted().joined(separator: ";") + "|\(model.finishedCleanupCount)"
    }

    private func measure() async {
        var total: Int64 = 0
        var found = false
        for id in model.orphanIDs.sorted() {
            guard let package = model.package(for: id) else { continue }
            let key = DiskUsage.cacheKey(for: id, version: model.installed[id]?.versions.last)
            if let measured = await DiskUsage.measuredBytes(
                key: key, roots: model.sizeRoots(for: package)) {
                total += measured
                found = true
            }
        }
        let result = found ? total : nil
        if result != leftoverBytes { leftoverBytes = result }
    }

    // MARK: - Empty state

    @ViewBuilder private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search
        } else if isChecking {
            WorkingCapsule(text: "Checking for updates…")
        } else {
            ContentUnavailableView {
                // Software Update's grammar: the good outcome, stated plainly as a sentence.
                Label("Everything looks good", systemImage: "checkmark.circle")
            } description: {
                Text("There's nothing to clean up or fix right now.")
            } actions: {
                Button("Check Again", action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Section-qualified row identity. The sections are disjoint by predicate, but they were not
/// always: both `ForEach`es identified rows by the bare `Package.ID`, and the one package that
/// landed in both made SwiftUI render the *first* section's view in both places — Alacritty
/// wore an Adopt button under "No longer maintained", and lost it under the section that owns
/// it. A row that silently offers the wrong action is worth these two lines to make
/// unrepresentable, whatever a third section might one day overlap with.
private struct RowItem: Identifiable {
    let kind: MaintenanceList
    let package: Package

    var id: String { "\(kind.rawValue)|\(package.id)" }
}

/// What `brew autoremove` would remove, in the storage card's shape: a count-led headline, the
/// space it frees, one button, one sentence. No rows — the command is bulk, so a row would be a
/// listing you cannot act on, and the confirmation dialog names the packages instead (the block
/// list's ≤4-in-full sampling rule).
private struct LeftoversCard: View {
    let bytes: Int64?

    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.orphanIDs.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(count == 1 ? "1 leftover package" : "\(count) leftover packages")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer(minLength: 12)

                if let bytes {
                    Text(bytes.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // The dialog lives on ContentView's root, so the Homebrew menu opens the very
                // same one. Bordered, never prominent — a destructive action doesn't get the
                // filled costume — and the ellipsis promises the dialog that follows.
                Button("Remove…") { model.confirmingAutoremove = true }
                    .buttonStyle(.bordered)
                    .disabled(model.autoremovePending)
                    .help("Removes packages nothing on this Mac uses")
            }

            Text("Installed automatically for something you've since removed. Nothing uses them now.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .contentBox()
    }
}

/// One maintenance row: the shared 32 pt tile, a title over a one-line state, a trailing
/// accessory. Selection and highlight are the List's; the row carries the cards' context-menu
/// subset (the shared rule: support context menus consistently).
private struct MaintenanceRow: View {
    let package: Package
    let kind: MaintenanceList

    @Environment(AppModel.self) private var model

    var body: some View {
        StateRow(title: package.title, subtitle: subtitle) {
            PackageIconView(package: package, size: 32)
        } accessory: {
            switch kind {
            case .unmanagedApps:
                // Adoption is offered one app at a time and never in bulk: an "Adopt All"
                // would make a per-app ownership claim for every ambiguous row at once,
                // silently. Services rows' trailing-control grammar.
                Button("Adopt…") { model.adopt(package) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Let Homebrew keep \(package.title) up to date")
            case .retired:
                if let version = model.installed[package.id]?.versions.last {
                    Text(version.shortVersion)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { PackageMenuItems(package: package) }
    }

    private var subtitle: String? {
        switch kind {
        case .unmanagedApps:
            // The caveat outranks the count: it is the fact that changes the answer. Adopting
            // a retired cask is allowed (deprecated is not disabled) but buys no updates, and
            // this row is the only place that can say so — the section above it promises the
            // opposite, and this app is deliberately not repeated under No longer maintained.
            if package.needsAttention { return "Homebrew no longer updates this one" }
            // Otherwise nothing when the app maps to one cask — the row used to repeat the
            // brew token under the app's own name ("alacritty" under "Alacritty"), which is
            // the app's name in lower case and told nobody anything. Ambiguity is worth a
            // line, because then the dialog will ask you to confirm *which* one.
            let candidates = model.unmanagedBundles.first { $0.value.contains(package.id) }?.value ?? []
            return candidates.count > 1 ? "\(candidates.count) possible matches" : nil
        case .retired:
            return package.attentionPhrase
        }
    }
}
