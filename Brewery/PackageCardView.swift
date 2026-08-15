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
    /// Whether the inspector is currently describing this package.
    var isSelected = false
    let onSelect: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

                // A hidden twin reserves the room the overlaid action control needs — always the
                // tallest variant, so a card's height never depends on which state it is in and
                // mixed rows stay flush.
                HStack(spacing: 8) {
                    if let command = hit.matchedCommand {
                        providesCaption(command)
                    }
                    Spacer(minLength: 0)
                    Button("Install") {}
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .hidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .buttonStyle(CardButtonStyle(isSelected: isSelected))
        .accessibilityHint("Shows package details")
        .overlay(alignment: .bottomTrailing) {
            actionButton
                .padding(12)
                .animation(.smooth(duration: 0.2), value: model.status(for: package))
        }
        // Right-click is a macOS reflex on any item (HIG Context menus: support them
        // consistently throughout the app — the tap rows already do). Small and relevant;
        // unavailable items are absent, not dimmed; everything here also exists in the main
        // interface, so the menu is pure convenience.
        .contextMenu { contextItems }
    }

    @ViewBuilder private var contextItems: some View {
        switch model.status(for: package) {
        case .notInstalled where !package.disabled:
            Button("Install") { model.install(package) }
        case .outdated where model.outdated[package.id]?.pinned != true:
            Button("Update") { model.upgrade(package) }
        case .installed:
            // Same rule as the action slot: only a single-bundle cask has something
            // unambiguous to open — the menu offered `first` of several, arbitrarily.
            let apps = model.launchableApps(for: package)
            if apps.count == 1, let app = apps.first {
                Button("Open") { model.openApp(at: app) }
            } else if apps.isEmpty, let font = model.installedFontURL(for: package) {
                Button("Open") { model.openFile(at: font) }
            }
        default:
            EmptyView()
        }
        if let url = package.homepageURL {
            Link("Open Homepage", destination: url)
        }
        Divider()
        // The brew token — what a terminal command or a bug report wants.
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(package.name, forType: .string)
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

    /// Pills for identity, one ·-joined text run for everything else — the App Store metadata
    /// pattern. Mixing capsules and bare values in alternation read as clutter, and a value
    /// sandwiched between two pills read worst of all.
    private var statusLine: some View {
        HStack(spacing: 6) {
            TagLabel(package.kindLabel, help: package.kindExplanation)
            // The owner half only ("charmbracelet") — the identity people recognize, and all
            // that fits beside kind + version; the full tap lives in the detail sheet. Core
            // items show nothing: the kind tag already implies core.
            if let owner = tapOwner {
                TagLabel(owner, help: "From the \(owner) tap — an extra catalog added to Homebrew")
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if let status = statusText {
                status
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    /// Version and state words as one concatenated `Text`, so per-segment colors survive and
    /// `lineLimit(1)` truncates the run as a unit.
    private var statusText: Text? {
        var segments: [Text] = []

        if let info = model.outdated[package.id] {
            segments.append(Text("\(info.installed.last?.shortVersion ?? "") → \(info.current.shortVersion)")
                .foregroundStyle(.orange))
        } else if let version = model.installed[package.id]?.versions.last, !version.isEmpty {
            segments.append(Text(version.shortVersion).foregroundStyle(.secondary))
        } else if !package.version.isEmpty {
            // Casks report versions like "2.1.50,56f0a83" — only the part a human reads is shown.
            segments.append(Text(package.version.shortVersion).foregroundStyle(.secondary))
        }

        if package.disabled {
            segments.append(Text("disabled").foregroundStyle(.red))
        } else if package.deprecated {
            segments.append(Text("deprecated").foregroundStyle(.red))
        }
        if model.outdated[package.id]?.pinned == true {
            segments.append(Text("pinned").foregroundStyle(.secondary))
        }
        if isDependency {
            segments.append(Text("dependency").foregroundStyle(.secondary))
        }

        guard let first = segments.first else { return nil }
        return segments.dropFirst().reduce(first) { run, segment in
            Text("\(run)\(Text(" · ").foregroundStyle(.tertiary))\(segment)")
        }
    }

    /// Installed, but nobody asked for it directly — the detail sheet's "Required by" says who did.
    private var isDependency: Bool {
        model.installed[package.id]?.onRequest == false
    }

    /// From the *effective* tap, so an item installed from a tap stays labelled even when a
    /// same-named core entry won the catalog slot.
    private var tapOwner: String? {
        model.effectiveTap(for: package).flatMap { $0.split(separator: "/").first.map(String.init) }
    }

    // MARK: - Action

    /// The control swaps as the package's state does — Install, then a spinner, then a checkmark.
    /// Replacing them in place keeps that legible as one thing changing — as a crossfade when
    /// Reduce Motion is on, since a blur replace animates into and out of a blur.
    private var actionButton: some View {
        actionControl.transition(reduceMotion ? AnyTransition.opacity
                                             : AnyTransition(.blurReplace))
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
                      ? "Homebrew has disabled \(package.title), so it can no longer be installed."
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
            // The App Store's grammar (v9): an installed app's button says Open. Single-bundle
            // casks get it — bordered, so the one filled button on a card stays the
            // state-changing one. Formulae and multi-app casks keep the state label: nothing
            // unambiguous to open (the detail pane's Open menu handles the multi-app few).
            let apps = model.launchableApps(for: package)
            if apps.count == 1, let app = apps.first {
                Button("Open") { model.openApp(at: app) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open \(app.deletingPathExtension().lastPathComponent)")
            } else if apps.isEmpty, let font = model.installedFontURL(for: package) {
                // Fonts launch too — into Font Book, the pane's grammar on the card.
                Button("Open") { model.openFile(at: font) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open \(package.title) in Font Book")
            } else {
                // A label, not a disabled button: state should not dress up as a dead control,
                // and disabled chrome washes the checkmark out to near-invisibility.
                Label {
                    Text("Installed").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.subheadline)
                .accessibilityLabel("Installed")
                .help("\(package.title) is installed.")
            }

        case .busy:
            // Status only — no cancel affordance on the card (a control here read as clutter
            // on a surface this small). Halting stays one click away where the queue lives:
            // the operations popover's row and the log window's toolbar, which keeps HIG
            // Progress indicators' "let people halt processing" satisfied app-wide while the
            // card stays macOS-quiet ("prefer an activity indicator to communicate the status
            // of a background operation").
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working on \(package.title)")
        }
    }
}

/// A subdued metadata capsule — what a package is, or why it is on disk. Deliberately quiet:
/// it is a label, and must never read as something to click.
struct TagLabel: View {
    let text: String
    /// Plain-words explanation for the hover tooltip — the jargon tags are where a
    /// non-technical user meets Homebrew's vocabulary.
    var help: String?

    init(_ text: String, help: String? = nil) {
        self.text = text
        self.help = help
    }

    var body: some View {
        let label = Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
        if let help {
            label.help(help)
        } else {
            label
        }
    }
}

/// Card chrome plus the hover, pressed and selected feedback macOS expects from a clickable
/// surface. Selected matters now that the inspector persists beside the grid: the card being
/// described has to be identifiable without reading the pane.
private struct CardButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isSelected: isSelected)
    }

    // A nested view, because a ButtonStyle cannot hold @State of its own.
    private struct Surface: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            // Pressed and selected wear the same accent border — a press is a selection about to
            // happen, so the card does not change costume between the two.
            let bordered = configuration.isPressed || isSelected

            configuration.label
                .background(shape.fill(.background.secondary))
                // Conditional, unlike the hover layer: selection changes are discrete, and 60 cards
                // are rebuilt on every keystroke — an always-present layer per card is rent.
                .overlay { if isSelected { shape.fill(.tint.quaternary) } }
                .overlay { shape.fill(.quaternary).opacity(isHovering ? 1 : 0) }
                .overlay {
                    shape.strokeBorder(bordered ? AnyShapeStyle(.tint)
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
