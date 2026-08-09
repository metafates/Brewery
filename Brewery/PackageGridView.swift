//
//  PackageGridView.swift
//  Brewery
//

import SwiftUI

/// A dumb renderer: whatever array it is handed, laid out as cards. Filtering, searching and
/// sectioning all happen in `ContentView`.
struct PackageGridView: View {
    let packages: [Package]
    let isSearching: Bool
    let onSelect: (Package) -> Void
    /// Shown when the section is empty for a reason other than the search, e.g. "Everything is up to date".
    var emptyMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        if packages.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(packages) { package in
                        PackageCardView(package: package) { onSelect(package) }
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
    PackageGridView(packages: [
        Package(kind: .formula, name: "wget", displayName: nil,
                desc: "Internet file retriever", homepage: "https://www.gnu.org/software/wget/",
                version: "1.25.0", deprecated: false, disabled: false),
        Package(kind: .cask, name: "iterm2", displayName: "iTerm2",
                desc: "Terminal emulator as alternative to Apple's Terminal app",
                homepage: "https://iterm2.com/", version: "3.5.11",
                deprecated: false, disabled: false)
    ], isSearching: false, onSelect: { _ in })
    .environment(AppModel())
    .frame(width: 600, height: 400)
}
