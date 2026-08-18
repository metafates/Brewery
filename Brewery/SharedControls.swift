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

/// The committed row grammar for "names another package": icon, title, optional secondary
/// line, trailing installed version, `chevron.right`. A real `Button` — keyboard and
/// VoiceOver reachable — whose action the host decides (the pane pushes, a report selects).
struct RelatedRow: View {
    let package: Package
    let version: String?
    /// Secondary line under the name — the conflict reason; nil for dependency rows.
    var detail: String? = nil
    /// v23.1 — true in wide content columns (the Checkup boxes): no hover pill, no chevron.
    /// Both are the narrow pane's tells; stretched across a wide column the pill reads as a
    /// giant card, and the chevron fights any trailing action button for the row's meaning
    /// (App Store's update rows at this width are static content plus a button).
    var inline: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PackageIconView(package: package, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(package.title)
                        .lineLimit(1)

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if let version, !version.isEmpty {
                    Text(version.shortVersion)
                        .foregroundStyle(.secondary)
                }

                if !inline {
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
            .background { shape.fill(.quaternary).opacity(isHovering && !inline ? 1 : 0) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(label)
        .accessibilityHint("Shows package details")
        .help("Show \(package.title)")
    }

    private var label: String {
        var parts = [package.title]
        if let version, !version.isEmpty { parts.append("version \(version.shortVersion)") }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }
}

/// Copies and says so: the glyph swaps to a checkmark for a beat — a silent copy button leaves
/// the user wondering whether anything happened.
struct CopyButton: View {
    let text: String

    @State private var copied = false

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
                .contentTransition(.symbolEffect(.replace.downUp, options: .speed(2)))
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
            .glassEffect()
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
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}
