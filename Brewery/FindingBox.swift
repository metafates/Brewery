//
//  FindingBox.swift
//  Brewery
//

import SwiftUI

/// One Checkup finding. The box reads top-down as brew wrote it: the problem, the
/// prose that introduces any commands, the commands the app can only offer for copying,
/// then everything it can do natively — Link rows, package rows, the Clean Up / Show in
/// Taps buttons — and links. Its own view with a stable identity (the finding text), so a
/// search-filter change moves boxes instead of re-purposing their subtrees' state, and
/// unchanged boxes skip their string parsing entirely.
struct FindingBox: View {
    let finding: DoctorReport.Finding

    @Environment(AppModel.self) private var model

    var body: some View {
        let presentation = FindingPresentation(finding: finding, package: model.package(for:))
        let affected = model.resolvedAffected(finding.affects ?? [])
            .filter { !presentation.represented.contains($0.id) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    // The Attention rule: warnings wear the banner's colour, not the tint.
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation.textBlocks.enumerated(), id: \.offset) { _, block in
                        findingBlock(block, structure: presentation.structure)
                    }
                }
            }

            // The prose introduces the commands, so it hides only when every command went
            // native — the action rows then say it themselves. A text-only remediation (the
            // untrusted-taps finding) keeps its prose: the text is all brew offered.
            if !presentation.chips.isEmpty || !presentation.hasRemedies {
                ForEach(presentation.remedyBlocks.enumerated(), id: \.offset) { _, block in
                    remediationBlock(block)
                }
            }
            ForEach(presentation.chips, id: \.self) { command in
                CodeChip(code: command)
            }

            ForEach(presentation.linkRows, id: \.name) { row in
                if let package = row.package {
                    HStack(spacing: 8) {
                        RelatedRow(package: package,
                                   version: model.installed[package.id]?.versions.last,
                                   inline: true) {
                            model.select(package)
                        }
                        linkControl(row.name)
                    }
                } else {
                    // Not in the catalog or overlays — the button still works; brew is the
                    // arbiter either way.
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        linkControl(row.name)
                    }
                    .padding(.horizontal, 6)
                }
            }

            ForEach(presentation.packageRows) { package in
                RelatedRow(package: package,
                           version: model.installed[package.id]?.versions.last,
                           inline: true) {
                    model.select(package)
                }
            }

            ForEach(affected) { package in
                RelatedRow(package: package,
                           version: model.installed[package.id]?.versions.last,
                           inline: true) {
                    model.select(package)
                }
            }

            if presentation.offersCleanup || presentation.offersTaps {
                HStack(spacing: 8) {
                    if presentation.offersCleanup { CleanupButton(isSmall: true) }
                    if presentation.offersTaps {
                        Button("Show in Taps") { model.requestShowTapList() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Taps are removed from the Taps list")
                    }
                }
                .padding(.top, 2)
            }

            ForEach(finding.links ?? [], id: \.self) { link in
                if let url = URL(string: link) {
                    Link(link, destination: url)
                        .font(.callout)
                        .pointerStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBox()
    }

    /// One block of the finding's own text. Code blocks are where the structure lives: the
    /// special findings' lists become rows, a lone URL becomes a link, and *anything* that
    /// fails its shape check — a future brew rewording, a list the resolver couldn't place —
    /// degrades to the copyable chip. Degrade, never crash, never hide.
    @ViewBuilder private func findingBlock(_ block: CaveatFormat.Block,
                                           structure: FindingFormat.Structure) -> some View {
        switch block {
        case .text(let paragraph):
            Text(CaveatFormat.attributed(paragraph))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            if structure == .pathShadowing, FindingFormat.toolList(inCode: code) != nil,
               !model.checkupShadowed.isEmpty {
                shadowedRows
            } else if structure == .untrustedTaps, let taps = FindingFormat.tapList(inCode: code) {
                tapRows(taps)
            } else if let url = FindingFormat.soleURL(inCode: code) {
                Link(url.absoluteString, destination: url)
                    .font(.callout)
                    .pointerStyle(.link)
            } else {
                CodeChip(code: code)
            }
        }
    }

    /// Remediation prose blocks — already deduplicated against the chips and links by
    /// `FindingFormat.remediationBlocks`.
    @ViewBuilder private func remediationBlock(_ block: CaveatFormat.Block) -> some View {
        switch block {
        case .text(let paragraph):
            Text(CaveatFormat.attributed(paragraph))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            if let url = FindingFormat.soleURL(inCode: code) {
                Link(url.absoluteString, destination: url)
                    .font(.callout)
                    .pointerStyle(.link)
            } else {
                CodeChip(code: code)
            }
        }
    }

    /// The PATH finding's tool list, resolved: one row per providing package, the affected
    /// commands in the detail slot, selection into the inspector — the report-page grammar.
    /// Tools the resolver couldn't place stay visible as a chip beneath.
    private var shadowedRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.checkupShadowed) { entry in
                RelatedRow(package: entry.package,
                           version: model.installed[entry.package.id]?.versions.last,
                           detail: FindingFormat.shadowsSubtitle(entry.tools),
                           inline: true) {
                    model.select(entry.package)
                }
            }
            if !model.checkupShadowedUnresolved.isEmpty {
                CodeChip(code: model.checkupShadowedUnresolved.joined(separator: "\n"))
            }
        }
    }

    /// The tap-trust finding's tap list as navigation rows. No Trust button here: the
    /// confirmation-gated native action lives on the tap page — one home per action.
    private func tapRows(_ taps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(taps, id: \.self) { tap in
                PaneRow(title: tap,
                        detail: "Untrusted — open to trust or remove",
                        paneTells: false,
                        action: { model.requestOpenTap(tap) }) {
                    TapTile(name: tap,
                            remote: model.tapInfos.first { $0.name == tap }?.remote,
                            size: 22)
                }
                .help("Opens \(tap) in Taps")
                .accessibilityHint("Opens the tap")
            }
        }
    }

    /// The Link button's three states, read from the queue: idle, busy, done. No dialog —
    /// link is non-destructive and reversible, the service-toggle rule.
    @ViewBuilder private func linkControl(_ name: String) -> some View {
        let operation = model.linkOperation(for: name)
        if let operation, !operation.isFinished || operation.awaitingRefresh {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Linking \(name)")
        } else if operation?.state == .succeeded {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                Text("Linked")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else {
            Button("Link") { model.link(name) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Runs brew link \(name)")
                .accessibilityLabel("Link \(name)")
        }
    }
}
