//
//  OrphanSummaryBar.swift
//  Brewery
//

import Foundation
import SwiftUI

/// v10 — the Orphans scope's header: the report's totals and its one action. **Remove All…**
/// is a native, confirmed operation (the ellipsis promises the dialog — HIG *Buttons*) that
/// enqueues `brew autoremove`: the deliberate exception to the no-removals whitelist,
/// admissible because it is argument-less by construction, scoped to what brew itself
/// computes as unneeded, and confirmed first — `untap`'s precedent for scoped removals.
/// Bordered, never prominent: destructive actions don't get the filled costume.
struct OrphanSummaryBar: View {
    @Environment(AppModel.self) private var model
    @State private var bytes: Int64?
    @State private var confirming = false

    private var ids: [Package.ID] { model.orphanIDs.sorted() }

    var body: some View {
        if !ids.isEmpty {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.3.trianglepath")
                    // The Discover tip's scale (TipView's glyph) — the report bars share its
                    // banner grammar, so they share its metrics.
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    // The size joins the line in place once measured — horizontal growth
                    // only, nothing below moves.
                    // The reclaimable component is non-breaking: a narrow bar wraps only at
                    // the separator, never inside "1,2 GB reclaimable".
                    Text("^[\(ids.count) orphaned dependencies](inflect: true)\(bytes.map { " · " + "\($0.formatted(.byteCount(style: .file))) reclaimable".replacing(" ", with: "\u{00A0}") } ?? "")")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Installed for packages you've since removed.")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Remove All…") { confirming = true }
                    .disabled(model.autoremovePending)
                    .help("Removes dependencies nothing needs anymore")
                    // Pluralized by hand: the ^[](inflect:) markdown renders fine in the
                    // bar's Text but arrives raw in a dialog title, wrapped in Text or not.
                    .confirmationDialog(
                        ids.count == 1
                            ? "Remove 1 orphaned dependency?"
                            : "Remove \(ids.count) orphaned dependencies?",
                        isPresented: $confirming, titleVisibility: .visible) {
                        Button("Remove All", role: .destructive) { model.autoremove() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("These are dependencies nothing needs anymore. You can install any of them again later.")
                    }
            }
            .contentBox()
            .task(id: ids) {
                bytes = nil
                guard let prefix = model.client.prefix else { return }
                var total: Int64 = 0
                for id in ids {
                    guard let (_, name) = Package.components(of: id) else { continue }
                    let key = DiskUsage.cacheKey(for: id, version: model.installed[id]?.versions.last)
                    let root = prefix.appending(path: "Cellar", directoryHint: .isDirectory)
                        .appending(path: name, directoryHint: .isDirectory)
                    total += await DiskUsage.measuredBytes(key: key, roots: [root]) ?? 0
                }
                bytes = total
            }
        }
    }
}
