//
//  PackageGridView.swift
//  Brewery
//

import SwiftUI

/// A dumb renderer: whatever hits it is handed, laid out as cards. Filtering, searching and
/// sectioning all happen in `ContentView`.
///
/// It is handed **only the cards it will render**, never the whole listing. That is not a
/// micro-optimisation: a view's stored properties live in SwiftUI's attribute graph, which copies
/// and compares them on every update, so a `[SearchHit]` of the full catalog cost ~6 s per
/// interaction even though `.prefix` meant just 60 of them were ever drawn. Windowing the
/// *rendering* is not enough — the array must not cross the view boundary at all.
struct PackageGridView: View {
    /// Exactly the cards to draw.
    let hits: [SearchHit]
    /// How many exist in total, so the grid knows whether to ask for more.
    let totalCount: Int
    let isSearching: Bool
    let onSelect: (Package) -> Void
    /// Shown when the section is empty for a reason other than the search, e.g. "Everything is up to date".
    var emptyMessage: String?
    /// Called when the end of the rendered window scrolls into view.
    let onNeedMore: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        if totalCount == 0 {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(hits) { hit in
                        PackageCardView(hit: hit) { onSelect(hit.package) }
                            // Cards that survive a search change slide to their new slot; the ones
                            // that come and go fade instead of popping, so the reflow reads as one
                            // set rearranging rather than the whole grid being replaced.
                            .transition(.opacity)
                    }
                    if hits.count < totalCount {
                        // Inside the grid so the lazy container withholds it until it is scrolled
                        // to; below the grid it would appear at once and unwind the whole list.
                        Color.clear
                            .frame(height: 1)
                            .onAppear(perform: onNeedMore)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search
        } else if let emptyMessage {
            ContentUnavailableView(emptyMessage, systemImage: "shippingbox")
        }
    }
}

#Preview {
    PackageGridView(hits: [
        SearchHit(package: Package(kind: .formula, name: "wget", displayName: nil,
                                   desc: "Internet file retriever",
                                   homepage: "https://www.gnu.org/software/wget/",
                                   version: "1.25.0", deprecated: false, disabled: false),
                  matchedCommand: nil),
        SearchHit(package: Package(kind: .cask, name: "iterm2", displayName: "iTerm2",
                                   desc: "Terminal emulator as alternative to Apple's Terminal app",
                                   homepage: "https://iterm2.com/", version: "3.5.11",
                                   deprecated: false, disabled: false),
                  matchedCommand: nil)
    ], totalCount: 2, isSearching: false, onSelect: { _ in }, onNeedMore: {})
    .environment(AppModel())
    .frame(width: 600, height: 400)
}
