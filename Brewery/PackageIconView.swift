//
//  PackageIconView.swift
//  Brewery
//

import SwiftUI

/// The package homepage's favicon, or an SF Symbol in a tinted rounded rect when there is no
/// homepage to ask about — or the fetch has not finished. Backed by `IconStore` rather than
/// `AsyncImage`: a cell scrolled out of the grid cancels this view's await, but the store's fetch
/// runs on regardless, so the icon is already cached when the cell comes back.
struct PackageIconView: View {
    let package: Package
    var size: CGFloat = 44

    /// Icons grow with the text they sit next to.
    @ScaledMetric(relativeTo: .headline) private var scale = 1

    @State private var image: NSImage?
    @State private var isLoading = false

    private var side: CGFloat { size * scale }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
    }

    /// Font casks never reach the store at all: a foundry's favicon says nothing about the
    /// typeface, so they always render the glyph.
    private var host: String? {
        guard !package.isFont, let host = package.homepageURL?.host(), !host.isEmpty else { return nil }
        return host
    }

    private var symbol: String {
        if package.isFont { return "textformat" }
        return package.kind == .formula ? "terminal.fill" : "macwindow"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(shape)
            } else {
                // Loading: the same fallback symbol, dimmed. No spinners in the grid.
                fallback.opacity(isLoading ? 0.4 : 1)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .task(id: host) {
            guard let host else {
                image = nil
                return
            }
            isLoading = true
            image = await IconStore.shared.icon(for: host)
            isLoading = false
        }
    }

    private var fallback: some View {
        shape
            .fill(.tint.quaternary)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.45))
                    .foregroundStyle(.tint)
            }
    }
}

#Preview {
    HStack {
        PackageIconView(package: Package(kind: .formula, name: "wget", displayName: nil,
                                         desc: nil, homepage: nil, version: "1.25.0",
                                         deprecated: false, disabled: false))
        PackageIconView(package: Package(kind: .cask, name: "iterm2", displayName: "iTerm2",
                                         desc: nil, homepage: nil, version: "3.5.11",
                                         deprecated: false, disabled: false), size: 88)
        PackageIconView(package: Package(kind: .cask, name: "font-fira-code", displayName: "Fira Code",
                                         desc: nil, homepage: "https://github.com/tonsky/FiraCode",
                                         version: "6.2", deprecated: false, disabled: false))
    }
    .padding()
}
