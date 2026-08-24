//
//  ReportListView.swift
//  Brewery
//

import SwiftUI

/// Which report a list is rendering; decides the row's subtitle and trailing value.
nonisolated enum ReportKind {
    case orphans, attention, storage
}

/// The reports' shared surface: state rows, not catalog cards. A report answers "what is
/// this item's state and what does it cost me" — the Services rule generalized — and iPhone
/// Storage's grammar answers it: size-sorted rows with a per-item value. Cards answered
/// "should I install this?", the wrong question for packages that are all installed.
/// Selection is the List's own (`List(selection:)` + `.tag`): the system draws the
/// rounded inset highlight, arrow keys work, and the rows share one gutter with the summary
/// bar, which rides in an ordinary row slot with its chrome margin removed.
struct ReportListView<Header: View>: View {
    @Environment(AppModel.self) private var model
    let hits: [SearchHit]
    let isSearching: Bool
    /// While any state work runs, an empty listing shows the working capsule instead of its
    /// claim — a claim is replaced, never contradicted, while it is recomputed.
    var isChecking = false
    var selectedID: Package.ID?
    let onSelect: (Package) -> Void
    let onRefresh: () -> Void
    let emptyMessage: String?
    let kind: ReportKind
    @ViewBuilder let header: Header

    /// Per-row bytes, published once per measure pass (the `measureSizes` lesson: row-by-row
    /// assignments would re-sort the list N times).
    @State private var bytes: [Package.ID: Int64] = [:]

    var body: some View {
        // One container either way: the empty state rides an overlay, so the header keeps the
        // list's own gutter instead of a hand-set twin, and the centering stays.
        List(selection: selection) {
            // An ordinary row slot: the list's own insets are the shared gutter, so the
            // bar's edges and the rows' content agree by construction. The bottom gap
            // matches the Discover tip's clearance from its cards — a banner needs air
            // before the content it summarizes.
            header
                .padding(.bottom, 14)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()

            ForEach(sortedHits) { hit in
                ReportRow(package: hit.package,
                          kind: kind,
                          bytes: bytes[hit.package.id])
                    .tag(hit.package.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if hits.isEmpty {
                emptyState
                    .animation(.smooth(duration: 0.3), value: isChecking)
            }
        }
        .task(id: measureKey) { await measure() }
    }

    /// The system draws the highlight; selecting routes through the app's one selection funnel.
    /// Deselection (⎋) is ignored — the inspector, not the list, owns "nothing is selected".
    private var selection: Binding<Package.ID?> {
        Binding(get: { selectedID },
                set: { id in
                    guard let id, let hit = hits.first(where: { $0.package.id == id }) else { return }
                    onSelect(hit.package)
                })
    }

    /// Browse order is largest-first — the report's own question is "where are the bytes" —
    /// but an active search stays relevance-ranked (the committed rule), and Attention has
    /// no byte axis, so it keeps the pipeline's name order.
    private var sortedHits: [SearchHit] {
        guard kind != .attention, !isSearching else { return hits }
        return hits.sorted { Package.sizeOrder($0.package, $1.package, sizes: bytes) }
    }

    /// Re-measure when the listed set changes or a cleanup finishes — the byte totals under
    /// unchanged names are exactly what cleanup moves.
    private var measureKey: String {
        let ids = hits.map(\.package.id).sorted().joined(separator: ";")
        return "\(ids)|\(model.finishedCleanupCount)"
    }

    private func measure() async {
        guard kind != .attention, let prefix = model.client.prefix else { return }
        var result: [Package.ID: Int64] = [:]
        for hit in hits {
            let package = hit.package
            switch kind {
            case .storage:
                // The old kegs only — what this row costs beyond the version that stays.
                guard let versions = model.installed[package.id]?.versions else { continue }
                var total: Int64 = 0
                var found = false
                for (key, root) in AppModel.oldKegRoots(
                    prefix: prefix, name: package.name, versions: versions) {
                    if let measured = await DiskUsage.measuredBytes(key: key, roots: [root]) {
                        total += measured
                        found = true
                    }
                }
                if found { result[package.id] = total }
            case .orphans:
                // The whole rack — what autoremove frees. Same keys the summary bar measures,
                // so the session cache shares every walk.
                let key = DiskUsage.cacheKey(for: package.id,
                                             version: model.installed[package.id]?.versions.last)
                if let measured = await DiskUsage.measuredBytes(
                    key: key, roots: model.sizeRoots(for: package)) {
                    result[package.id] = measured
                }
            case .attention:
                break
            }
        }
        if result != bytes { bytes = result }
    }

    @ViewBuilder private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search
        } else if isChecking {
            // The overlay centers it; the capsule's own fill makes it cover the listing slot.
            WorkingCapsule(text: "Checking for updates…")
        } else {
            ContentUnavailableView {
                // The section's own glyph — one shippingbox meant four things (the Services
                // rule: the empty state wears its section's symbol).
                Label(emptyMessage ?? "Nothing to report", systemImage: symbol)
            } description: {
                Text(emptyDescription)
            } actions: {
                Button("Check Again", action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var symbol: String {
        switch kind {
        case .orphans: "arrow.3.trianglepath"
        case .attention: "exclamationmark.triangle"
        case .storage: "internaldrive"
        }
    }

    private var emptyDescription: String {
        switch kind {
        case .orphans: "Dependencies nothing installed still needs appear here."
        case .attention: "Installed packages Homebrew has deprecated or disabled appear here."
        case .storage: "Formulae keeping old versions on disk appear here."
        }
    }
}

/// One report row: 32 pt icon, title over a one-line state, a trailing value. Selection and
/// highlight are the List's; the row carries the cards' context-menu subset (the shared rule:
/// support context menus consistently).
private struct ReportRow: View {
    let package: Package
    let kind: ReportKind
    let bytes: Int64?

    @Environment(AppModel.self) private var model

    var body: some View {
        StateRow(title: package.title, subtitle: subtitle) {
            PackageIconView(package: package, size: 32)
        } accessory: {
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        // The shared package base every package row carries.
        .contextMenu { PackageMenuItems(package: package) }
    }

    private var subtitle: String? {
        switch kind {
        case .storage:
            let count = (model.installed[package.id]?.versions.count ?? 1) - 1
            return count == 1 ? "1 old version" : "\(count) old versions"
        case .orphans:
            // Orphans are the catalog's obscure corners — the desc answers "what even is this".
            return package.desc
        case .attention:
            return package.attentionPhrase
        }
    }

    private var trailing: String? {
        switch kind {
        case .storage, .orphans:
            return bytes?.formatted(.byteCount(style: .file))
        case .attention:
            return model.installed[package.id]?.versions.last?.shortVersion
        }
    }
}
