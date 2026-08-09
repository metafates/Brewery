//
//  PackageIconView.swift
//  Brewery
//

import SwiftUI

/// The package homepage's favicon, or an SF Symbol in a tinted rounded rect when there is no
/// homepage to ask about — or the download has not finished. Deliberately a plain `AsyncImage`:
/// `URLCache.shared` is configured app-wide, so caching needs no code here.
struct PackageIconView: View {
    let package: Package
    var size: CGFloat = 44

    /// Icons grow with the text they sit next to.
    @ScaledMetric(relativeTo: .headline) private var scale = 1

    private var side: CGFloat { size * scale }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
    }

    var body: some View {
        Group {
            if let url = package.iconURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(shape)
                    case .empty:
                        // Loading: the fallback symbol, dimmed. No spinners in the grid.
                        fallback.opacity(0.4)
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        shape
            .fill(.tint.quaternary)
            .overlay {
                Image(systemName: package.kind == .formula ? "terminal.fill" : "macwindow")
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
    }
    .padding()
}
