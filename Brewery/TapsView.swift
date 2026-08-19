//
//  TapsView.swift
//  Brewery
//

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
    let onSelect: (String) -> Void

    @Environment(AppModel.self) private var model
    /// Focus and activation, split (Finder's grammar): arrow keys move a real, persistent
    /// selection; Return and a click open the tap. Drilling on selection *change* cannot
    /// work — the page covers and disables the list mid-traversal.
    @State private var focusedTap: String?
    @State private var tip = TapsTip()
    /// TipView hides itself once dismissed, but the row it sits in would keep its insets — the
    /// gap would read as a layout bug. Gate the whole row on the tip's own status instead.
    @State private var showTip = false

    var body: some View {
        // v24 — selection is the List's own (the report lists' rule); a click or Return
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
                    BuiltInTapRow(row: row)
                        .tag(row.name)
                        .onTapGesture { onSelect(row.name) }
                }
            } header: {
                // A header labels its group. The vocabulary that used to hang under it is the
                // tip's job now, and formula-vs-cask is already Discover's tip and the tag
                // tooltips — HIG *Offering help*: "Avoid bloating your help content."
                Text("Built-in")
            }

            Section {
                if filteredInfos.isEmpty {
                    Text(searchText.isEmpty ? "No taps yet — use the Add Tap button in the toolbar."
                                            : "No taps match the search.")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(filteredInfos) { info in
                        TapRow(info: info,
                               installedCount: model.installedCount(fromTap: info.name),
                               trust: model.trustState,
                               onRemove: { model.pendingTapRemoval = info },
                               onUntrust: { model.untrustTap(info.name) })
                            .tag(info.name)
                            .onTapGesture { onSelect(info.name) }
                    }
                }
            } header: {
                Text("Your Taps")
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            guard let focusedTap else { return .ignored }
            onSelect(focusedTap)
            return .handled
        }
        .task {
            for await status in tip.statusUpdates {
                showTip = status == .available
            }
        }
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

private struct BuiltInTapRow: View {
    let row: TapsView.BuiltIn

    var body: some View {
        StateRow(title: row.name,
                 subtitle: "\(row.count.formatted(.number)) \(row.kindLabel)") {
            TapTile(name: row.name)
        } accessory: {
            TagLabel("Built-in")
                .font(.caption)
        }
        .accessibilityHint("Shows the tap's packages")
    }
}

private struct TapRow: View {
    let info: TapInfo
    let installedCount: Int
    let trust: TrustState
    let onRemove: () -> Void
    let onUntrust: () -> Void

    var body: some View {
        StateRow(title: info.name, subtitle: contents) {
            TapTile(name: info.name, remote: info.remote)
        } accessory: {
            trustBadge
        }
        .accessibilityHint("Shows the tap's packages")
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

    /// Quiet when all is well; orange when brew is hiding things from the user.
    @ViewBuilder private var trustBadge: some View {
        if trust.isTrusted(info.name) {
            Label("Trusted", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let items = trust.trustedItemCount(in: info.name)
            Label(items > 0 ? "\(items) item\(items == 1 ? "" : "s") trusted" : "Untrusted",
                  systemImage: items > 0 ? "shield.lefthalf.filled" : "shield.slash")
                .font(.caption)
                .foregroundStyle(.orange)
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
