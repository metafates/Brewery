//
//  ReportListView.swift
//  Brewery
//

import AppKit
import SwiftUI

/// v20 — which report a list is rendering; decides the row's subtitle and trailing value.
nonisolated enum ReportKind {
    case orphans, attention, storage
}

/// v20 — the reports' shared surface: state rows, not catalog cards. A report answers "what is
/// this item's state and what does it cost me" — the Services rule generalized — and iPhone
/// Storage's grammar answers it: size-sorted rows with a per-item value. Cards answered
/// "should I install this?", the wrong question for packages that are all installed.
/// Rows select into the inspector; the section's summary bar rides as the list's first row.
struct ReportListView<Header: View>: View {
    @Environment(AppModel.self) private var model
    let hits: [SearchHit]
    let isSearching: Bool
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
        Group {
            if hits.isEmpty {
                VStack(spacing: 0) {
                    header
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    // The bar carries its own chrome and margins; the row slot contributes none.
                    header
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    ForEach(sortedHits) { hit in
                        ReportRow(package: hit.package,
                                  kind: kind,
                                  bytes: bytes[hit.package.id],
                                  isSelected: hit.package.id == selectedID,
                                  onSelect: { onSelect(hit.package) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: measureKey) { await measure() }
    }

    /// Browse order is largest-first — the report's own question is "where are the bytes" —
    /// but an active search stays relevance-ranked (v11's committed rule), and Attention has
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
        } else {
            ContentUnavailableView {
                Label(emptyMessage ?? "Nothing to report", systemImage: "shippingbox")
            } actions: {
                Button("Check Again", action: onRefresh)
            }
        }
    }
}

/// One report row: ServiceRow's chrome — icon, title, a state line, a trailing value — with
/// the cards' context-menu subset (the v9 rule: support context menus consistently).
private struct ReportRow: View {
    let package: Package
    let kind: ReportKind
    let bytes: Int64?
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                PackageIconView(package: package, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                if let trailing {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows package details")
        .padding(.vertical, 3)
        .listRowBackground(Rectangle().fill(isSelected ? AnyShapeStyle(.tint.quaternary)
                                                       : AnyShapeStyle(.clear)))
        .contextMenu {
            if let url = package.homepageURL {
                Link("Open Homepage", destination: url)
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.name, forType: .string)
            }
            // Every report row is an installed package; App Store's Delete-last grammar.
            if !model.isPinned(package), model.status(for: package) != .busy {
                Divider()
                Button("Uninstall…", role: .destructive) { model.uninstall(package) }
            }
        }
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
