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

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .background { shape.fill(.quaternary).opacity(isHovering ? 1 : 0) }
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
