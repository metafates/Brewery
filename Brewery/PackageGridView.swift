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
struct PackageGridView<Header: View>: View {
    /// Exactly the cards to draw.
    let hits: [SearchHit]
    /// How many exist in total, so the grid knows whether to ask for more.
    let totalCount: Int
    let isSearching: Bool
    /// The card the inspector is describing, so it can read as selected. A single id, never a set:
    /// see the note above about what crossing this boundary costs.
    var selectedID: Package.ID?
    let onSelect: (Package) -> Void
    /// Shown when the section is empty for a reason other than the search, e.g. "Everything is up to date".
    var emptyMessage: String?
    /// The section's own glyph for that state (the Services rule).
    var emptySymbol = "shippingbox"
    /// Called when the end of the rendered window scrolls into view.
    let onNeedMore: () -> Void
    /// Offered in the empty state where re-checking is the useful next move — "Everything is up to
    /// date" invites exactly that question. Omitted where it is not, such as a filter hiding
    /// everything on Discover.
    var onRefresh: (() -> Void)?
    /// While any state work runs (`AppModel.isChecking`), an empty section must not claim
    /// "Everything is up to date" — the answer is still being computed. Spinner instead (HIG
    /// Progress indicators, macOS: a spinner for a background operation, description where
    /// helpful); a claim is replaced, never contradicted, while it is recomputed.
    var isChecking = false
    /// Set when a filter emptied the listing: clearing the filters is the fix Check Again
    /// cannot be.
    var onClearFilters: (() -> Void)? = nil
    /// An optional page header that scrolls with the content — the App Store pattern. A fixed
    /// header above the ScrollView fights macOS's scroll-under-chrome behavior and clips cards.
    /// A stored view, not a closure: the synthesized memberwise init builds it, and the
    /// 19-line hand-written restatement of every property goes with it.
    @ViewBuilder let header: Header

    private static var columns: [GridItem] { [GridItem(.adaptive(minimum: 230), spacing: 12)] }

    var body: some View {
        if totalCount == 0 {
            VStack(spacing: 0) {
                header
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.smooth(duration: 0.3), value: isChecking)
            }
        } else {
            ScrollView {
                header
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(hits) { hit in
                        // The nil check first on purpose: `Package.id` interpolates a fresh string,
                        // and with the pane closed — which is most of the time, including every
                        // keystroke of a search — no card needs to build one to know it is not it.
                        PackageCardView(hit: hit,
                                        isSelected: selectedID != nil && hit.package.id == selectedID) {
                            onSelect(hit.package)
                        }
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
        } else if isChecking {
            // Software Update's grammar: the wait first, the claim ("Everything is up to
            // date") only once the check has finished — in the app's one working chip.
            WorkingCapsule(text: "Checking for updates…")
        } else if let emptyMessage {
            ContentUnavailableView {
                // The section's own glyph (the Services rule) — one shippingbox meant
                // four different things.
                Label(emptyMessage, systemImage: emptySymbol)
            } description: {
                EmptyView()
            } actions: {
                if let onClearFilters {
                    Button("Clear Filters", action: onClearFilters)
                        .buttonStyle(.borderedProminent)
                } else if let onRefresh {
                    Button("Check Again", action: onRefresh)
                        .buttonStyle(.borderedProminent)
                }
            }
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
    ], totalCount: 2, isSearching: false, onSelect: { _ in }, onNeedMore: {},
       header: { EmptyView() })
    .environment(AppModel())
    .frame(width: 600, height: 400)
}
