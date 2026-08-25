//
//  MaintenanceView.swift
//  Brewery
//

import SwiftUI

/// One band of the Maintenance page. Each answers a different question — reclaim space, these
/// will stop working, these aren't managed — but they share one question above them: *what
/// should I do about my Homebrew?* Four sidebar destinations made that question un-askable,
/// because none of them carried a badge (a passive report is not pending work) and the only
/// way to learn whether anything needed doing was to visit all four.
///
/// Membership deliberately overlaps: a formula can keep old versions *and* be an orphan, and
/// both statements stay true. Each section filters the page's listing independently rather
/// than partitioning it.
nonisolated enum MaintenanceSection: String, CaseIterable, Identifiable {
    case oldVersions, orphans, attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldVersions: "Old Versions"
        case .orphans: "Orphaned Dependencies"
        case .attention: "Needs Attention"
        }
    }

    /// The glyph each of these wore as its own destination, kept so the empty states and the
    /// section headers stay recognisable to anyone who knew the old pages.
    var symbol: String {
        switch self {
        case .oldVersions: "internaldrive"
        case .orphans: "arrow.3.trianglepath"
        case .attention: "exclamationmark.triangle"
        }
    }

    /// The prose the deleted summary bars carried. It has no room in a section header, so it
    /// appears where it is actually useful: in the section's own empty state, explaining what
    /// *would* be listed here.
    var explainer: String {
        switch self {
        case .oldVersions: "Formulae keeping superseded versions on disk appear here."
        case .orphans: "Dependencies installed for packages you've since removed appear here."
        case .attention: "Packages Homebrew has deprecated or disabled appear here. Each package's page says why, and what to use instead."
        }
    }

    /// Sections with a byte axis measure; Attention has none — a deprecation costs no space.
    var measuresBytes: Bool { self != .attention }
}

/// The maintenance surface: one page, one list, one selection. The storage gauge rides the
/// header slot as the aggregate answer, then each section discloses in place.
///
/// **Disclosure, not drill-down.** HIG *macOS* asks for "fewer nested levels and less need for
/// modality", and this app's stat grammar already assigns `chevron.down` to "discloses below"
/// against `chevron.right`'s "navigates deeper". A landing page of summary rows that pushed
/// detail pages would read well and put every row one navigation level further away than it
/// was as four destinations — a regression wearing a tidier surface. Collapsed, these headers
/// *are* that landing page; expanding costs no navigation.
///
/// Checkup stays its own destination on a real axis, not a squeamish one: every section here
/// is computed from data the app already holds and is always current, while a checkup needs a
/// subprocess and is run on demand — which is also why it owns four states this page has no
/// use for.
struct MaintenanceView: View {
    /// The union of every section's packages, ranked when a search is active. One array across
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

    /// Expansion persists per section: which bands you care about is personalization, and the
    /// collapsed page is the summary, so the default costs nothing to read.
    @AppStorage("maintenance.expand.oldVersions") private var expandOldVersions = false
    @AppStorage("maintenance.expand.orphans") private var expandOrphans = false
    @AppStorage("maintenance.expand.attention") private var expandAttention = false

    /// Per-row bytes, **per band**, published once per measure pass (the `measureSizes`
    /// lesson: row-by-row assignment would re-sort every section N times).
    ///
    /// Two dictionaries, not one: the same package can be listed in both bands and the bands
    /// ask different questions — Old Versions costs the superseded kegs, an orphan costs its
    /// whole rack, because that is what each band's action reclaims. One dictionary forced a
    /// branch on live `orphanIDs`, which the fixpoint can flip while the installed overlay is
    /// still settling; the wrong branch then cached a whole-rack figure under a key that did
    /// not record the choice, so `neovim` was measured at 59,3 MB in a band that should have
    /// said 29,6 MB and the header over-reported the total by exactly one keg.
    @State private var oldKegBytes: [Package.ID: Int64] = [:]
    @State private var rackBytes: [Package.ID: Int64] = [:]

    var body: some View {
        // Resolved once per pass: `orphanIDs` runs a fixpoint, and each section's filter walks
        // the listing. Three passes, not three per section per row.
        let buckets = self.buckets

        return List(selection: selection) {
            // An ordinary row slot, so the list's own insets are the shared gutter and the
            // gauge's edges agree with the rows' content by construction.
            StorageSummaryBar()
                .padding(.bottom, 14)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()

            section(.oldVersions, hits: buckets[.oldVersions] ?? [], isExpanded: $expandOldVersions)
            section(.orphans, hits: buckets[.orphans] ?? [], isExpanded: $expandOrphans)
            section(.attention, hits: buckets[.attention] ?? [], isExpanded: $expandAttention)
        }
        .listStyle(.inset)
        .overlay {
            if buckets.values.allSatisfy(\.isEmpty) {
                emptyState
                    .animation(.smooth(duration: 0.3), value: isChecking)
            }
        }
        .task(id: measureKey) { await measure() }
    }

    // MARK: - Sections

    /// Membership overlaps by design, so each section filters the listing rather than claiming
    /// a slice of it: `ffmpeg` can be listed under Old Versions *and* Orphaned Dependencies,
    /// and removing it and cleaning it up are different acts with different consequences.
    private var buckets: [MaintenanceSection: [SearchHit]] {
        let orphans = model.orphanIDs
        return [
            .oldVersions: hits.filter {
                $0.package.kind == .formula && (model.installed[$0.package.id]?.versions.count ?? 0) > 1
            },
            .orphans: hits.filter { orphans.contains($0.package.id) },
            .attention: hits.filter(\.package.needsAttention),
        ]
    }

    @ViewBuilder
    private func section(_ kind: MaintenanceSection,
                         hits sectionHits: [SearchHit],
                         isExpanded: Binding<Bool>) -> some View {
        // An empty section during a search would be four headers over nothing; while browsing
        // it is the honest "this one is fine", which the page's own empty state already says
        // once every section is empty.
        if !sectionHits.isEmpty {
            // `DisclosureGroup`, not `Section(isExpanded:)`: measured on macOS 26.5, an
            // expandable Section under `.listStyle(.inset)` renders its header and **no
            // triangle**, leaving the band with no way to open. The group draws its own, and
            // draws it as `chevron.right` → `chevron.down` — the app's committed stat grammar
            // for "discloses below" — rather than borrowing the sidebar style's.
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(sorted(sectionHits, in: kind)) { hit in
                    MaintenanceRow(package: hit.package, kind: kind,
                                   bytes: measured(hit.package.id, in: kind))
                        .tag(hit.package.id)
                }
            } label: {
                header(kind, hits: sectionHits)
            }
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }

    private func header(_ kind: MaintenanceSection, hits sectionHits: [SearchHit]) -> some View {
        HStack(spacing: 8) {
            Text(kind.title)
            Text(count(sectionHits.count, in: kind))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if kind.measuresBytes, let total = totalBytes(of: sectionHits, in: kind) {
                Text(total.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            action(for: kind)
        }
        // A section header is the band's name and its one action, not a shouted label: the
        // count and value read as data, which uppercasing destroys.
        .textCase(nil)
        .font(.subheadline)
    }

    /// A band's action, in the grammar the deleted summary bars used: bordered and never
    /// prominent (a destructive action doesn't get the filled costume), and the ellipsis
    /// promising the dialog that follows. The dialog lives on ContentView's root, so the
    /// Homebrew menu opens the very same one.
    ///
    /// Old Versions deliberately carries **none**: `brew cleanup` is a single command that
    /// also sweeps the download cache and the logs, so a button in that band would name a
    /// scope it cannot keep. The gauge above owns Clean Up… because the gauge's scope *is*
    /// cleanup's scope — and two buttons for one command read as two different acts.
    @ViewBuilder
    private func action(for kind: MaintenanceSection) -> some View {
        switch kind {
        case .oldVersions:
            EmptyView()
        case .orphans:
            Button("Remove All…") { model.confirmingAutoremove = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.autoremovePending)
                .help("Removes dependencies nothing needs anymore")
        case .attention:
            // Deliberately none: nothing safe to enqueue exists — uninstalling is a non-goal —
            // and a warning is not a task. The per-package specifics live in the pane.
            EmptyView()
        }
    }

    private func count(_ value: Int, in kind: MaintenanceSection) -> String {
        switch kind {
        case .oldVersions: value == 1 ? "1 formula" : "\(value) formulae"
        case .orphans, .attention: value == 1 ? "1 package" : "\(value) packages"
        }
    }

    /// What a row costs *in this band*: superseded kegs under Old Versions, the whole rack
    /// under Orphaned Dependencies. Attention has no byte axis at all.
    private func measured(_ id: Package.ID, in kind: MaintenanceSection) -> Int64? {
        switch kind {
        case .oldVersions: oldKegBytes[id]
        case .orphans: rackBytes[id]
        case .attention: nil
        }
    }

    /// Largest-first where there is a byte axis — the band's own question is "where are the
    /// bytes" — except while searching, where relevance order is the committed rule.
    private func sorted(_ sectionHits: [SearchHit], in kind: MaintenanceSection) -> [SearchHit] {
        guard kind.measuresBytes, !isSearching else { return sectionHits }
        let sizes = kind == .orphans ? rackBytes : oldKegBytes
        return sectionHits.sorted { Package.sizeOrder($0.package, $1.package, sizes: sizes) }
    }

    private func totalBytes(of sectionHits: [SearchHit], in kind: MaintenanceSection) -> Int64? {
        let measured = sectionHits.compactMap { self.measured($0.package.id, in: kind) }
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }

    // MARK: - Selection

    /// The system draws the highlight; selecting routes through the app's one selection funnel.
    /// Deselection (⎋) is ignored — the inspector, not the list, owns "nothing is selected".
    ///
    /// The tag stays the bare `Package.ID` even though a package can be listed in two bands: a
    /// selection names *the package the pane is describing*, which is true of both of its rows,
    /// so highlighting both is the honest answer rather than a duplicate-tag accident.
    private var selection: Binding<Package.ID?> {
        Binding(get: { selectedID },
                set: { id in
                    guard let id, let hit = hits.first(where: { $0.package.id == id }) else { return }
                    onSelect(hit.package)
                })
    }

    // MARK: - Measurement

    /// Re-measure when the listed set changes or a cleanup finishes — the byte totals under
    /// unchanged names are exactly what cleanup moves.
    private var measureKey: String {
        let ids = hits.map(\.package.id).sorted().joined(separator: ";")
        return "\(ids)|\(model.finishedCleanupCount)"
    }

    private func measure() async {
        guard let prefix = model.client.prefix else { return }
        let buckets = self.buckets
        var kegs: [Package.ID: Int64] = [:]
        var racks: [Package.ID: Int64] = [:]

        // Old Versions: only what `brew cleanup` would trim — every keg but the newest. The
        // same keys the gauge above measures, so the session cache shares every walk and the
        // band's total and the gauge's "Old versions" segment agree by construction.
        for hit in buckets[.oldVersions] ?? [] {
            guard let versions = model.installed[hit.package.id]?.versions else { continue }
            var total: Int64 = 0
            var found = false
            for (key, root) in AppModel.oldKegRoots(
                prefix: prefix, name: hit.package.name, versions: versions) {
                if let measured = await DiskUsage.measuredBytes(key: key, roots: [root]) {
                    total += measured
                    found = true
                }
            }
            if found { kegs[hit.package.id] = total }
        }

        // Orphans: the whole rack — that is what autoremove frees.
        for hit in buckets[.orphans] ?? [] {
            let key = DiskUsage.cacheKey(for: hit.package.id,
                                         version: model.installed[hit.package.id]?.versions.last)
            if let measured = await DiskUsage.measuredBytes(
                key: key, roots: model.sizeRoots(for: hit.package)) {
                racks[hit.package.id] = measured
            }
        }

        if kegs != oldKegBytes { oldKegBytes = kegs }
        if racks != rackBytes { rackBytes = racks }
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
                Label("Nothing needs maintenance", systemImage: "checkmark.circle")
            } description: {
                Text("Homebrew is tidy: no old versions on disk, nothing orphaned, nothing deprecated.")
            } actions: {
                Button("Check Again", action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One maintenance row: the shared 32 pt tile, a title over a one-line state, a trailing
/// value. Selection and highlight are the List's; the row carries the cards' context-menu
/// subset (the shared rule: support context menus consistently).
private struct MaintenanceRow: View {
    let package: Package
    let kind: MaintenanceSection
    let bytes: Int64?

    @Environment(AppModel.self) private var model

    var body: some View {
        StateRow(title: package.title, subtitle: subtitle) {
            PackageIconView(package: package, size: 32)
        } accessory: {
            if kind.measuresBytes, let bytes {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if kind == .attention, let version = model.installed[package.id]?.versions.last {
                Text(version.shortVersion)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { PackageMenuItems(package: package) }
    }

    private var subtitle: String? {
        switch kind {
        case .oldVersions:
            let count = (model.installed[package.id]?.versions.count ?? 1) - 1
            return count == 1 ? "1 old version" : "\(count) old versions"
        case .orphans:
            // Orphans are the catalog's obscure corners — the desc answers "what even is this".
            return package.desc
        case .attention:
            return package.attentionPhrase
        }
    }
}
