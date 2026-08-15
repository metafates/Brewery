//
//  PackageIconView.swift
//  Brewery
//

import AppKit
import SwiftUI

/// The installed bundle's real icon when a cask's `.app` is on disk (v10 — identity straight
/// from the app itself, no network), else the package homepage's favicon, else an SF Symbol in
/// a tinted rounded rect. Favicons are backed by `IconStore` rather than `AsyncImage`: a cell
/// scrolled out of the grid cancels this view's await, but the store's fetch runs on
/// regardless, so the icon is already cached when the cell comes back.
struct PackageIconView: View {
    let package: Package
    var size: CGFloat = 44

    /// Icons grow with the text they sit next to.
    @ScaledMetric(relativeTo: .headline) private var scale = 1

    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var isAppIcon = false
    @State private var isLoading = false

    /// macOS app icons pad their squircle inside the canvas (the HIG icon grid: an 824 pt
    /// squircle centered in a 1024 pt canvas), so drawn at tile size they read visibly
    /// smaller than the edge-to-edge favicon tiles beside them. Overscanning by the grid
    /// ratio puts the squircle exactly at the tile bounds, under the same rounded clip both
    /// species now share; the baked margin shadow falls outside the clip, which favicon
    /// tiles never had either. Legacy full-bleed icons don't break this: the system masks
    /// them into the grid before icon services hands them over.
    private static let appIconOverscan: CGFloat = 1024 / 824

    private var side: CGFloat { size * scale }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
    }

    /// Font casks never reach the store at all: a foundry's favicon says nothing about the
    /// typeface, so they always render the glyph. Forge-hosted homepages don't either (v10):
    /// GitHub's and GitLab's favicons are one logo repeated across half the catalog — chrome
    /// pretending to be identity — so they skip the fetch and wear the ordinary kind glyph.
    /// (A GitHub-mark tile shipped first and read as a fourth package kind next to the
    /// terminal, app and font glyphs; the tile's glyph is kind vocabulary.)
    private var host: String? {
        guard !package.isFont, let host = package.homepageURL?.host()?.lowercased(),
              !host.isEmpty, !Self.forgeHosts.contains(host) else { return nil }
        return host
    }

    private static let forgeHosts: Set<String> = [
        "github.com", "www.github.com", "gitlab.com", "www.gitlab.com",
    ]

    private var symbol: String {
        if package.isFont { return "textformat" }
        return package.kind == .formula ? "terminal.fill" : "macwindow"
    }

    /// The installed bundle whose icon beats any favicon. Resolved per appearance like the
    /// pane's Open target, so an app dragged to the Trash falls back to the favicon.
    private var installedAppPath: String? {
        guard package.kind == .cask else { return nil }
        return model.launchableApps(for: package).first?.path
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(isAppIcon ? Self.appIconOverscan : 1)
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                // Loading: the same fallback symbol, dimmed. No spinners in the grid.
                fallback.opacity(isLoading ? 0.4 : 1)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        // Icons arrive whenever the network says so. Crossfading the swap is the difference between
        // a grid that fills in and a grid that flickers as you scroll through it.
        .animation(.easeOut(duration: 0.2), value: image == nil)
        .accessibilityHidden(true)
        .task(id: "\(installedAppPath ?? "")|\(host ?? "")") {
            if let path = installedAppPath {
                // Icon services answers from its own cache; the reps cover retina sizes.
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 256, height: 256)
                image = icon
                isAppIcon = true
                return
            }
            guard let host else {
                image = nil
                isAppIcon = false
                return
            }
            isLoading = true
            image = await IconStore.shared.icon(for: host)
            isAppIcon = false
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
    .environment(AppModel())
    .padding()
}
