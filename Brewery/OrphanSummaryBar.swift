//
//  OrphanSummaryBar.swift
//  Brewery
//

import Foundation
import SwiftUI

/// The Orphans scope's header: the report's totals and its one action. **Remove All…**
/// is a native, confirmed operation (the ellipsis promises the dialog — HIG *Buttons*) that
/// enqueues `brew autoremove`: the deliberate exception to the no-removals whitelist,
/// admissible because it is argument-less by construction, scoped to what brew itself
/// computes as unneeded, and confirmed first — `untap`'s precedent for scoped removals.
/// Bordered, never prominent: destructive actions don't get the filled costume.
struct OrphanSummaryBar: View {
    @Environment(AppModel.self) private var model
    @State private var bytes: Int64?

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

                // The dialog lives on ContentView's root — the Homebrew menu opens the same one.
                Button("Remove All…") { model.confirmingAutoremove = true }
                    .disabled(model.autoremovePending)
                    .help("Removes dependencies nothing needs anymore")
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
