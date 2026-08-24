//
//  TapsView.swift
//  Brewery
//

import AppKit
import SwiftUI
import TipKit

/// The one thing a newcomer has to be told here, in the grammar Discover already uses for the
/// same job (`PackageKindsTip`): a dismissible card, remembered, rather than a paragraph welded
/// under the toolbar forever. HIG *Onboarding*: "Consider providing a collection of
/// context-specific tips instead of a single onboarding flow."
struct TapsTip: Tip {
    var title: Text {
        Text("Taps are package catalogs")
    }

    var message: Text? {
        Text("Homebrew ships two. Developers publish more — and anything they list installs like any other package.")
    }

    /// "prefer the filled variant" (HIG *Offering help* → Creating tips) of the glyph the rows wear.
    var image: Image? {
        Image(systemName: "spigot.fill")
    }
}

/// The Taps section's list: built-in catalogs pinned on top, then the cloned taps with their
/// contents, install counts, freshness and brew 6 trust state. Rows open the tap's package page.
struct TapsView: View {
    let searchText: String
    /// Any state work in flight (`AppModel.isChecking`): the tap rescan rides every refresh,
    /// so while one runs an empty "Your Taps" section must not claim "No taps yet".
    var isChecking = false
    let onSelect: (String) -> Void

    @Environment(AppModel.self) private var model
    /// Focus and activation, split: arrow keys move a real selection; Return opens it. Clicks
    /// never touch it — every row is a `DrillRow` button that consumes them — so the highlight
    /// is keyboard-only and transient (the push clears it; a navigation list keeps no highlight
    /// after back). Drilling on selection *change* cannot work — the page covers and disables
    /// the list mid-traversal.
    @State private var focusedTap: String?
    @State private var tip = TapsTip()
    /// TipView hides itself once dismissed, but the row it sits in would keep its insets — the
    /// gap would read as a layout bug. Gate the whole row on the tip's own status instead.
    @State private var showTip = false

    var body: some View {
        // Selection is the List's own (the report lists' rule); a click or Return
        // opens the selected tap.
        List(selection: $focusedTap) {
            if showTip {
                Section {
                    TipView(tip)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
            }

            Section {
                ForEach(builtInRows, id: \.name) { row in
                    BuiltInTapRow(row: row, onOpen: { open(row.name) })
                        .tag(row.name)
                }
            } header: {
                // A header labels its group. The vocabulary that used to hang under it is the
                // tip's job now, and formula-vs-cask is already Discover's tip and the tag
                // tooltips — HIG *Offering help*: "Avoid bloating your help content."
                Text("Built-in")
            }

            Section {
                if filteredInfos.isEmpty {
                    if isChecking, searchText.isEmpty {
                        // The claim is being recomputed — a wait may only occupy space that
                        // has nothing to show, and a row slot wears the caption grammar (the
                        // Outdated freshness caption's): the capsule fills pages, not rows.
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for updates…")
                        }
                        .accessibilityElement(children: .combine)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                    } else {
                        Text(searchText.isEmpty ? "No taps yet — use the Add Tap button in the toolbar."
                                                : "No taps match the search.")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                } else {
                    ForEach(filteredInfos) { info in
                        TapRow(info: info,
                               installedCount: model.installedCount(fromTap: info.name),
                               trust: model.trustState,
                               onOpen: { open(info.name) },
                               onRemove: { model.pendingTapRemoval = info },
                               onUntrust: { model.untrustTap(info.name) })
                            .tag(info.name)
                    }
                }
            } header: {
                Text("Your Taps")
            }
        }
        .listStyle(.inset)
        // A navigation list's selection is transient: the push consumes it. A highlight
        // surviving the back trip would claim a relationship the page's dismissal ended
        // (System Settings keeps none). Cleared under the covering page, so back lands clean.
        .onChange(of: model.selectedTap) {
            if model.selectedTap != nil { focusedTap = nil }
        }
        // The .inset style's structural row margin (~10 pt outside the cell, measured) cannot
        // belong to the row button — a click there still lands on List selection. A mouse-set
        // selection IS that click, and it meant "open" (System Settings paints the same flash
        // before its push); a key-set selection is the arrows' highlight and must stay.
        .onChange(of: focusedTap) {
            guard let focusedTap,
                  let event = NSApp.currentEvent,
                  event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
            open(focusedTap)
        }
        .onKeyPress(.return) {
            guard let focusedTap else { return .ignored }
            open(focusedTap)
            return .handled
        }
        .task {
            for await status in tip.statusUpdates {
                showTip = status == .available
            }
        }
    }

    /// The one activation funnel: clears any highlight a mouse-down may have painted before
    /// the row button fired (and the same-row case `onChange` cannot see), then pushes.
    private func open(_ name: String) {
        focusedTap = nil
        onSelect(name)
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var filteredInfos: [TapInfo] {
        guard !query.isEmpty else { return model.tapInfos }
        return model.tapInfos.filter { $0.name.lowercased().contains(query) }
    }

    struct BuiltIn { let name: String; let count: Int; let kindLabel: String }

    /// The API-backed core taps: not clones, not removable, implicitly trusted.
    private var builtInRows: [BuiltIn] {
        let rows = [
            BuiltIn(name: "homebrew/core",
                    count: model.catalog.count { $0.kind == .formula && $0.tap == nil },
                    kindLabel: "formulae"),
            BuiltIn(name: "homebrew/cask",
                    count: model.catalog.count { $0.kind == .cask && $0.tap == nil },
                    kindLabel: "casks"),
        ]
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.name.contains(query) }
    }
}

/// The drill-row tell (System Settings grammar, PaneRow's chevron): a single click anywhere
/// on the row pushes the tap's page, and the row says so. Decorative — the rows' accessibility
/// hint already carries the promise.
private struct DrillChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// The drill row's whole-cell button: row insets zeroed, the list gutter moved inside the
/// label, so every pixel of the row band belongs to the button — a click can open but never
/// select (selection is the arrow keys'; System Settings keeps no highlight from clicks).
/// The gap between the two shapes was the bug: the List's selectable band exceeded the
/// row's hit shape, and a click in the difference painted a highlight that opened nothing.
private struct DrillRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                // The `.inset` style's default row gutter (16 h / 4 v, measured), relocated
                // inside the button so the label — and its hit shape — owns the full cell.
                .padding(.vertical, 4)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .accessibilityHint("Shows the tap's packages")
    }
}

private struct BuiltInTapRow: View {
    let row: TapsView.BuiltIn
    let onOpen: () -> Void

    var body: some View {
        DrillRow(action: onOpen) {
            StateRow(title: row.name,
                     subtitle: "\(row.count.formatted(.number)) \(row.kindLabel)") {
                TapTile(name: row.name)
            } accessory: {
                // No "Built-in" pill: the section header already says it once for the group.
                DrillChevron()
            }
        }
    }
}

private struct TapRow: View {
    let info: TapInfo
    let installedCount: Int
    let trust: TrustState
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onUntrust: () -> Void

    var body: some View {
        DrillRow(action: onOpen) {
            StateRow(title: info.name, subtitle: contents) {
                TapTile(name: info.name, remote: info.remote)
            } accessory: {
                HStack(spacing: 8) {
                    trustException
                    DrillChevron()
                }
            }
        }
        .contextMenu {
            if trust.taps.contains(info.name.lowercased()) {
                // Only for *explicit* trust: official taps cannot be untrusted, and partial
                // (per-item) trust is brew's own bookkeeping.
                Button("Untrust") { onUntrust() }
            }
            Button("Remove Tap…", role: .destructive, action: onRemove)
        }
    }

    private var contents: String {
        var parts: [String] = []
        if info.formulaCount > 0 {
            parts.append("\(info.formulaCount) \(info.formulaCount == 1 ? "formula" : "formulae")")
        }
        if info.caskCount > 0 {
            parts.append("\(info.caskCount) \(info.caskCount == 1 ? "cask" : "casks")")
        }
        if parts.isEmpty { parts.append("empty") }
        if installedCount > 0 { parts.append("\(installedCount) installed") }
        return parts.joined(separator: " · ")
    }

    /// Quiet when all is well — a trusted tap says nothing (labeling the normal state on
    /// every row is noise); only the exception speaks, in the Services rows' dot grammar.
    @ViewBuilder private var trustException: some View {
        if !trust.isTrusted(info.name) {
            let items = trust.trustedItemCount(in: info.name)
            StatusDotLabel(text: items > 0 ? "\(items) item\(items == 1 ? "" : "s") trusted"
                                           : "Untrusted",
                           color: .orange)
                .font(.caption)
        }
    }
}

/// The tap page's header. It scrolls with the grid (the App Store pattern — a fixed header above
/// a macOS ScrollView fights the scroll-under-chrome behavior and clips cards). When brew
/// distrusts the tap, the notice is a real banner with the remedy inside it: a confirmation-gated
/// Trust action — a floating warning with no way to act on it is an accusation, not an interface.
struct TapPageHeader: View {
    let tap: String

    @Environment(AppModel.self) private var model
    @State private var confirmingTrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                if let remote = info?.remote, let url = URL(string: remote) {
                    Link(destination: url) {
                        Label(url.host() ?? remote, systemImage: "globe")
                    }
                    .pointerStyle(.link)
                }
                if let checked = info?.lastChecked {
                    Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if info != nil {
                    headerMenu
                }
            }
            .font(.callout)

            if let info, !model.trustState.isTrusted(info.name) {
                trustBanner(info)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The detail sheet's deprecated/disabled banner language, with the action where the
    /// problem is stated.
    private func trustBanner(_ info: TapInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not trusted by Homebrew")
                        .fontWeight(.semibold)
                    Text("Its services and some listings stay hidden. Installing a package trusts just that package; trusting the tap covers everything it ships.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "shield.slash")
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            Button("Trust This Tap…") { confirmingTrust = true }
                .confirmationDialog("Trust \(info.name)?", isPresented: $confirmingTrust,
                                    titleVisibility: .visible) {
                    // Echo the trigger's verb (every other dialog pair does).
                    Button("Trust Tap") { model.trustTap(info.name) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Homebrew will run this tap's recipes when listing and installing. Only trust taps whose authors you trust.")
                }
        }
        .warningWash(.orange)
        .accessibilityElement(children: .contain)
    }

    /// The list row context menu's twin in the main interface (the pane's moreMenu rule):
    /// Untrust only where explicit trust exists, then the destructive Remove behind a
    /// divider, funneling into the one removal dialog.
    private var headerMenu: some View {
        Menu {
            if let info, model.trustState.taps.contains(info.name.lowercased()) {
                Button("Untrust") { model.untrustTap(info.name) }
                Divider()
            }
            if let info {
                Button("Remove Tap…", role: .destructive) { model.pendingTapRemoval = info }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(tap)")
    }

    private var info: TapInfo? {
        model.tapInfos.first { $0.name == tap }
    }
}

/// The add-tap popover: one field, live validation, and an honest caption about what tapping does.
struct AddTapPopover: View {
    let onAdd: (String) -> Void

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool { AppModel.isValidTapName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Tap")
                .font(.headline)

            TextField("user/repo", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { if isValid { submit() } }

            Text("Clones github.com/\(namePreview). Its packages stay untrusted until you install one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)

            HStack {
                Spacer()
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(14)
    }

    private var namePreview: String {
        guard isValid else { return "user/homebrew-repo" }
        let parts = name.lowercased().split(separator: "/")
        return "\(parts[0])/homebrew-\(parts[1])"
    }

    private func submit() {
        onAdd(name)
        dismiss()
    }
}
