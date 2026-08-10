//
//  PackageCardView.swift
//  Brewery
//

import SwiftUI

/// One App Store-like card: icon, name, status line, description, and whatever action applies to
/// the package right now. The whole card is a button that opens the detail sheet; the action button
/// is overlaid rather than nested so both stay individually clickable and focusable.
struct PackageCardView: View {
    let hit: SearchHit
    let onSelect: () -> Void

    @Environment(AppModel.self) private var model

    private var package: Package { hit.package }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    PackageIconView(package: package)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.title)
                            .font(.headline)
                            .lineLimit(1)
                        statusLine
                    }

                    Spacer(minLength: 0)
                }

                Text(package.desc ?? "No description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    // Reserved so every card in a row is the same height.
                    .lineLimit(2, reservesSpace: true)

                // A hidden twin reserves exactly the room the overlaid action button needs,
                // whatever the text size — and leaves the rest of that row for the caption.
                HStack(spacing: 8) {
                    if let command = hit.matchedCommand {
                        providesCaption(command)
                    }
                    Spacer(minLength: 0)
                    actionButton.hidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityHint("Shows package details")
        .overlay(alignment: .bottomTrailing) {
            actionButton
                .padding(12)
                .animation(.smooth(duration: 0.2), value: model.status(for: package))
        }
    }

    /// Why this card is here at all: a package matched only because it provides the executable the
    /// user typed reads as a false positive without saying so. It rides the row the action button
    /// already reserves, so a captioned card is exactly as tall as its neighbours.
    private func providesCaption(_ command: String) -> some View {
        Text("Provides \(Text(command).monospaced())")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 6) {
            TagLabel(package.kindLabel)
            versionLabel
            if package.disabled {
                Text("disabled").foregroundStyle(.red)
            } else if package.deprecated {
                Text("deprecated").foregroundStyle(.red)
            }
            if model.outdated[package.id]?.pinned == true {
                Text("pinned").foregroundStyle(.secondary)
            }
            if isDependency {
                TagLabel("dependency")
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    /// Installed, but nobody asked for it directly — the detail sheet's "Required by" says who did.
    private var isDependency: Bool {
        model.installed[package.id]?.onRequest == false
    }


    /// Casks report versions like "2.1.50,56f0a83" — only the part a human reads is shown.
    @ViewBuilder
    private var versionLabel: some View {
        if let info = model.outdated[package.id] {
            Text("\(info.installed.last?.shortVersion ?? "") → \(info.current.shortVersion)")
                .foregroundStyle(.orange)
        } else if let version = model.installed[package.id]?.versions.last, !version.isEmpty {
            Text(version.shortVersion).foregroundStyle(.secondary)
        } else if !package.version.isEmpty {
            Text(package.version.shortVersion).foregroundStyle(.secondary)
        }
    }

    // MARK: - Action

    /// The control swaps as the package's state does — Install, then a spinner, then a checkmark.
    /// Replacing them in place keeps that legible as one thing changing.
    private var actionButton: some View {
        actionControl.transition(.blurReplace)
    }

    @ViewBuilder
    private var actionControl: some View {
        switch model.status(for: package) {
        case .notInstalled:
            Button("Install") { model.install(package) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(package.disabled)
                .help(package.disabled
                      ? "\(package.title) is disabled and can no longer be installed."
                      : "Install \(package.title)")

        case .outdated:
            let pinned = model.outdated[package.id]?.pinned == true
            Button("Update") { model.upgrade(package) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pinned)
                .help(pinned ? "\(package.title) is pinned, so Brewery leaves it alone."
                             : "Update \(package.title)")

        case .installed:
            // A disabled button: the checkmark is an affordance, not an action.
            Button(action: {}) {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(true)
            .accessibilityLabel("Installed")
            .help("\(package.title) is installed.")

        case .busy:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working on \(package.title)")
                // Only when this package has its own operation: a card made busy by Upgrade All has
                // nothing of its own to stop.
                if let operation = model.activeOperation(for: package) {
                    Button { model.cancel(operation) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
                    .accessibilityLabel("Cancel \(package.title)")
                }
            }
        }
    }
}

/// A subdued metadata capsule — what a package is, or why it is on disk. Deliberately quiet:
/// it is a label, and must never read as something to click.
struct TagLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }
}

/// Card chrome plus the hover and pressed feedback macOS expects from a clickable surface.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    // A nested view, because a ButtonStyle cannot hold @State of its own.
    private struct Surface: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

            configuration.label
                .background(shape.fill(.background.secondary))
                .overlay { shape.fill(.quaternary).opacity(isHovering ? 1 : 0) }
                .overlay {
                    shape.strokeBorder(configuration.isPressed ? AnyShapeStyle(.tint)
                                                              : AnyShapeStyle(.separator),
                                       lineWidth: 1)
                }
                .contentShape(shape)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

#Preview {
    PackageCardView(hit: SearchHit(package: Package(kind: .cask, name: "iterm2",
                                                    displayName: "iTerm2",
                                                    desc: "Terminal emulator as alternative to Apple's Terminal app",
                                                    homepage: "https://iterm2.com/",
                                                    version: "3.5.11",
                                                    deprecated: false, disabled: false),
                                   matchedCommand: nil),
                    onSelect: {})
    .environment(AppModel())
    .frame(width: 260)
    .padding()
}
