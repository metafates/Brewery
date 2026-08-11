//
//  TapsView.swift
//  Brewery
//

import SwiftUI

/// The Taps section's list: built-in catalogs pinned on top, then the cloned taps with their
/// contents, install counts, freshness and brew 6 trust state. Rows open the tap's package page.
struct TapsView: View {
    let searchText: String
    let onSelect: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var removing: TapInfo?

    var body: some View {
        List {
            Section {
                ForEach(builtInRows, id: \.name) { row in
                    BuiltInTapRow(row: row, onSelect: { onSelect(row.name) })
                }
            } header: {
                // Orientation copy reads best *before* the rows — a footer teaches you what a
                // list was only after you've read it.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Built in")
                    Text("Formulae are command-line tools, casks are Mac apps.")
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }

            Section {
                if filteredInfos.isEmpty {
                    Text(searchText.isEmpty ? "No taps added yet — use + to add one."
                                            : "No taps match the search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredInfos) { info in
                        TapRow(info: info,
                               installedCount: model.installedCount(fromTap: info.name),
                               trust: model.trustState,
                               onSelect: { onSelect(info.name) },
                               onRemove: { removing = info },
                               onUntrust: { model.untrustTap(info.name) })
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your taps")
                    Text("Extra catalogs published by developers. Anything they list installs like any other package.")
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog(removalTitle, isPresented: removalPresented, titleVisibility: .visible) {
            if let info = removing, model.installedCount(fromTap: info.name) == 0 {
                Button("Remove Tap", role: .destructive) { model.removeTap(info.name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let info = removing {
                if model.installedCount(fromTap: info.name) > 0 {
                    Text("Homebrew refuses to remove a tap while packages from it are installed. Uninstall them first.")
                } else {
                    Text("The tap's local copy is removed; it can be added again anytime. If Homebrew trusts it, that trust survives and reapplies on re-adding.")
                }
            }
        }
    }

    private var removalTitle: String {
        removing.map { "Remove \($0.name)?" } ?? ""
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var filteredInfos: [TapInfo] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.tapInfos }
        return model.tapInfos.filter { $0.name.lowercased().contains(query) }
    }

    struct BuiltIn { let name: String; let count: Int; let kindLabel: String }

    /// The API-backed core taps: not clones, not removable, implicitly trusted.
    private var builtInRows: [BuiltIn] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
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

/// The shared leading tile — taps have no favicon worth fetching (they are all GitHub repos),
/// so the app's tap glyph does the identifying.
private struct TapTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.quaternary.opacity(0.6))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "spigot")
                    .foregroundStyle(.secondary)
            }
    }
}

private struct BuiltInTapRow: View {
    let row: TapsView.BuiltIn
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    TapTile()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text("\(row.count.formatted(.number)) \(row.kindLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            TagLabel("Built in")
                .font(.caption)
        }
        .padding(.vertical, 3)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

private struct TapRow: View {
    let info: TapInfo
    let installedCount: Int
    let trust: TrustState
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onUntrust: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    TapTile()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.name)
                        Text(contents)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the tap's packages")

            trustBadge
        }
        .padding(.vertical, 3)
        // Separators follow the first text otherwise, leaving stray fragments under the badges.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
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
                        Label(url.host() ?? remote, systemImage: "safari")
                    }
                    .pointerStyle(.link)
                }
                if let checked = info?.lastChecked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
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
                    Text("Its services and some listings stay hidden. Installing an item trusts that item; trusting the tap covers everything it ships.")
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
                    Button("Trust") { model.trustTap(info.name) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Homebrew will run this tap's package definitions when listing and installing. Only trust taps whose authors you trust.")
                }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
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

            Text("Clones github.com/\(namePreview). Formulae from it stay untrusted until you install one.")
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
        isValid ? "\(name.lowercased().split(separator: "/")[0])/homebrew-\(name.lowercased().split(separator: "/")[1])"
                : "user/homebrew-repo"
    }

    private func submit() {
        onAdd(name)
        dismiss()
    }
}
