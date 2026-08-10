//
//  PackageGridView.swift
//  Brewery
//

import SwiftUI

/// A dumb renderer: whatever hits it is handed, laid out as cards. Filtering, searching and
/// sectioning all happen in `ContentView`.
struct PackageGridView: View {
    let hits: [SearchHit]
    let isSearching: Bool
    let onSelect: (Package) -> Void
    /// Shown when the section is empty for a reason other than the search, e.g. "Everything is up to date".
    var emptyMessage: String?
    /// Changing this resets the render window — the grid is listing something else now.
    var resetToken: AnyHashable

    /// `LazyVGrid` is lazy about *rendering*, not about identity diffing: handing it ~16k cards at
    /// once (clearing a search does exactly that) costs a visible hitch. Cards come 300 at a time,
    /// extended by a sentinel at the end of the list — continuous scroll, no page controls.
    private static let windowStep = 300

    @State private var window = PackageGridView.windowStep

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        // The reset sits above the branch on purpose: mounted inside the grid it would miss every
        // token change made while the empty state was showing, and the window would come back stale.
        content
            .onChange(of: resetToken) { window = PackageGridView.windowStep }
    }

    @ViewBuilder private var content: some View {
        if hits.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(hits.prefix(window)) { hit in
                        PackageCardView(hit: hit) { onSelect(hit.package) }
                    }
                    if window < hits.count {
                        // Inside the grid so the lazy container withholds it until it is scrolled
                        // to; below the grid it would appear at once and unwind the whole list.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { window += PackageGridView.windowStep }
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
    ], isSearching: false, onSelect: { _ in }, resetToken: 0)
    .environment(AppModel())
    .frame(width: 600, height: 400)
}
