//
//  SharedControls.swift
//  Brewery
//
//  v19 — three controls hoisted out of PackageDetailView when the Checkup report needed them:
//  the navigation row for "names another package", the copy-confirming button, and the
//  monospaced command chip. Same grammar in the pane and on report pages.
//

import AppKit
import SwiftUI

/// v24 — the pane's row chrome, one home: `.plain` button, subheadline, hover pill, chevron.
/// `RelatedRow` and the pane's `CommandsRow` were two hand-copies of it.
struct PaneRow<Leading: View>: View {
    let title: String
    /// Secondary line under the title — the conflict reason; caption-sized (a subtitle at the
    /// title's size read as a second title).
    var detail: String? = nil
    var trailing: String? = nil
    /// v23.1 — false in wide content columns (the Checkup boxes): the hover pill and chevron
    /// are the narrow pane's tells; stretched wide the pill reads as a giant card, and the
    /// chevron fights any trailing action button for the row's meaning.
    var paneTells: Bool = true
    let action: () -> Void
    @ViewBuilder let leading: Leading

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                }

                if paneTells {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .background { shape.fill(.quaternary).opacity(isHovering && paneTells ? 1 : 0) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }
}

/// The committed row grammar for "names another package": icon, title, optional secondary
/// line, trailing installed version. A real `Button` — keyboard and VoiceOver reachable —
/// whose action the host decides (the pane pushes, a report page selects).
struct RelatedRow: View {
    let package: Package
    let version: String?
    var detail: String? = nil
    var inline: Bool = false
    let action: () -> Void

    var body: some View {
        PaneRow(title: package.title,
                detail: detail,
                trailing: version?.isEmpty == false ? version?.shortVersion : nil,
                paneTells: !inline,
                action: action) {
            PackageIconView(package: package, size: 22)
        }
        .accessibilityLabel(label)
        .accessibilityHint("Shows package details")
        .help("Show \(package.title)")
        // The v9 rule: every package row supports the same context-menu base.
        .contextMenu { PackageMenuItems(package: package) }
    }

    private var label: String {
        var parts = [package.title]
        if let version, !version.isEmpty { parts.append("version \(version.shortVersion)") }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

/// v24 — the context-menu base every package row shares (v9's consistency rule): homepage,
/// the brew token, and — for uninstallable installed packages — App Store's Delete-last
/// grammar. Surfaces prepend their own verbs (a card's Install, a service row's Start).
struct PackageMenuItems: View {
    let package: Package

    @Environment(AppModel.self) private var model

    var body: some View {
        if let url = package.homepageURL {
            Link("Open Homepage", destination: url)
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(package.name, forType: .string)
        }
        switch model.status(for: package) {
        case .installed, .outdated:
            if !model.isPinned(package) {
                Divider()
                Button("Uninstall…", role: .destructive) { model.uninstall(package) }
            }
        default:
            EmptyView()
        }
    }
}

/// v24 — the page-level box chrome (report bars, finding boxes), one home: continuous
/// curvature on *both* the fill and the stroke — the layers drifted apart per surface.
struct ContentBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.background.secondary,
                        in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

extension View {
    func contentBox() -> some View { modifier(ContentBox()) }
}

/// v24 — the pane's section heading, one home (it was inlined three times).
struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.bottom, 2)
    }
}

/// v24 — the one Clean Up button: trigger, dialog and disabled rule together, so the Storage
/// bar and the Checkup finding can't drift (the copy already shared via `CleanupDialog`).
struct CleanupButton: View {
    var isSmall: Bool = false

    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        Button("Clean Up…") { confirming = true }
            .buttonStyle(.bordered)
            .controlSize(isSmall ? .small : .regular)
            .disabled(model.cleanupPending)
            .help("Removes files Homebrew no longer needs")
            .confirmationDialog(CleanupDialog.title,
                                isPresented: $confirming, titleVisibility: .visible) {
                Button(CleanupDialog.confirm, role: .destructive) { model.cleanUp() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(CleanupDialog.message)
            }
    }
}

/// Copies and says so: the glyph swaps to a checkmark for a beat — a silent copy button leaves
/// the user wondering whether anything happened.
struct CopyButton: View {
    let text: String

    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                // The z-axis story: the old glyph recedes, the new one arrives — and the same
                // motion plays the reset. Doubled speed; a confirmation should be a blink.
                // Reduce Motion swaps in place — the checkmark is the feedback, not the ride.
                .contentTransition(reduceMotion ? .identity
                                                : .symbolEffect(.replace.downUp, options: .speed(2)))
                // Both glyphs live in one fixed box — without it the swap reflows the row by
                // the width difference between the two symbols.
                .frame(width: 18, height: 16)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy command")
    }
}

/// v24 — the one list row: a 32 pt tile, a title over a caption subtitle, a trailing
/// accessory. ServiceRow, TapRow, BuiltInTapRow and ReportRow were four hand-copies of this
/// shape, drifting in vertical padding (3/3/4) and separator rules. Selection belongs to the
/// List (`List(selection:)` + `.tag`), so the row is content only — no inner Button.
struct StateRow<Tile: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    var subtitleMonospaced = false
    var subtitleTruncation: Text.TruncationMode = .tail
    @ViewBuilder let tile: Tile
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            tile

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(subtitleMonospaced ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(subtitleTruncation)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(.vertical, 4)
        // Separators hang from the title, not the tile — the platform's list geometry.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 44 }
    }
}

/// v22 — the app's one "working" chip: the rotating-arrows label in a glass capsule that the
/// refresh veil committed. One component, one spinner grammar — the Checkup page briefly grew
/// a stock starburst spinner beside it, and two working styles read as two apps.
struct WorkingCapsule: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(text, systemImage: "arrow.triangle.2.circlepath")
            .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            // A standard material, not Liquid Glass: glass belongs to the chrome layer, and
            // this chip renders in content — including over the veil's blurred cards.
            .background(.regularMaterial, in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

/// v21 — the cleanup confirmation's copy, one home for its two surfaces (the Storage bar and
/// the Checkup remediation button) so they cannot drift.
nonisolated enum CleanupDialog {
    static let title = "Clean up Homebrew files?"
    static let confirm = "Clean Up"
    static let message = "Removes old versions of installed packages, stale downloads, and logs older than 30 days. Pinned and currently linked versions are kept."
}

/// One command run — meant to be executed, so it comes with a copy button. Copyable, never
/// executable: arbitrary command strings stay outside the whitelist by construction.
struct CodeChip: View {
    let code: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(code)
                .font(.callout)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CopyButton(text: code)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: .rect(cornerRadius: 6))
    }
}

/// The tap identity tile — the tap owner's GitHub avatar (v10: being GitHub repos is what
/// makes tap identity *fetchable*, the Sources-list grammar of Login Items and account
/// lists), the spigot glyph while it loads or when the remote isn't GitHub. Same fallback
/// discipline as `PackageIconView`: dimmed glyph while loading, crossfade on arrival.
/// Hoisted from TapsView (v25.1) when the Checkup tap-trust finding became its second
/// consumer.
struct TapTile: View {
    let name: String
    var remote: String? = nil
    var size: CGFloat = 32

    /// Tiles grow with the text beside them — PackageIconView's rule, so the two species
    /// sharing a row grammar scale together.
    @ScaledMetric(relativeTo: .headline) private var scale = 1

    @State private var image: NSImage?
    @State private var isLoading = false

    private var side: CGFloat { size * scale }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                shape
                    .fill(.quinary)
                    .overlay {
                        Image(systemName: "spigot")
                            .foregroundStyle(.secondary)
                    }
                    .opacity(isLoading ? 0.6 : 1)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.2), value: image == nil)
        .accessibilityHidden(true)
        .task(id: "\(name)|\(remote ?? "")") {
            guard let source = IconStore.avatarSource(tapName: name, remote: remote) else {
                image = nil
                return
            }
            isLoading = true
            image = await IconStore.shared.image(key: source.key, url: source.url)
            isLoading = false
        }
    }
}

extension View {
    /// ⌘R feedback in the content itself, not just the toolbar glyph: the listing stays put but
    /// recedes — blurred and dimmed, never hidden, because the data on screen is still valid while
    /// it is re-checked — behind a glass capsule naming the work. On a warm cache the whole thing
    /// is a soft half-second pulse, which is exactly the acknowledgment a fast refresh needs.
    /// Worn by the grid and by an open detail pane's content alike.
    func refreshVeil(_ active: Bool,
                     text: String = "Checking for updates…",
                     showsCapsule: Bool = true) -> some View {
        modifier(RefreshVeil(active: active, text: text, showsCapsule: showsCapsule))
    }

    /// The wash behind an inline warning — a deprecated package, an untrusted tap. Shared so the
    /// two banners cannot drift apart, and so the tint answers Increase Contrast in one place: a
    /// fixed 10% wash ignores the setting, and the system's own answer is a stronger fill plus the
    /// border it adds to controls.
    func warningWash(_ tint: Color) -> some View {
        modifier(WarningWash(tint: tint))
    }
}

struct WarningWash: ViewModifier {
    let tint: Color

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let increased = contrast == .increased
        return content
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(increased ? 0.22 : 0.1), in: shape)
            .overlay { if increased { shape.strokeBorder(tint.opacity(0.5)) } }
    }
}

/// A modifier rather than a plain extension so it can read Reduce Motion: animating into and out
/// of a blur, and sustaining a rotation, are two of the effects that setting exists to remove. The
/// dimming survives — it is the part that carries the meaning.
struct RefreshVeil: ViewModifier {
    let active: Bool
    var text = "Checking for updates…"
    /// v24 — false on a secondary column (the inspector): it blurs and dims with everything
    /// else, but only one capsule narrates a wait — two capsules read as two waits.
    var showsCapsule = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .blur(radius: active && !reduceMotion ? 6 : 0)
            .opacity(active ? 0.5 : 1)
            // Receded means receded: content blurred past legibility must not stay clickable —
            // what it looks like and what it does have to agree. `.disabled`, not a hit-test
            // block, so the cards leave the Tab order too. Only the veiled pane locks; sidebar,
            // toolbar, search and menu commands stay live (HIG Loading: let people do other
            // things while they wait).
            .disabled(active)
            .overlay {
                if active, showsCapsule {
                    WorkingCapsule(text: text)
                        .transition(reduceMotion ? AnyTransition.opacity
                                                : AnyTransition(.blurReplace))
                }
            }
            .animation(.smooth(duration: 0.3), value: active)
    }
}
