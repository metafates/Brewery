//
//  PackageDetailView.swift
//  Brewery
//

import SwiftUI

/// The sheet behind a card: everything the grid had no room for — the full description, why an
/// action may be unavailable, where the package comes from, what it pulled in (and what pulled it
/// in), and the log of the last operation that touched it.
struct PackageDetailView: View {
    let package: Package

    /// What the sheet currently shows. A dependency row retargets it in place, so following the
    /// graph needs no navigation stack and leaves the sheet presentation in `ContentView` alone.
    @State private var displayed: Package

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(package: Package) {
        self.package = package
        _displayed = State(initialValue: package)
    }

    var body: some View {
        // Resolved once per pass: both lists were read three times each (the `isEmpty` guards, the
        // rows, and the height), rebuilding the same arrays every time.
        let deps = dependencies
        let requiredBy = dependents

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if displayed.disabled || displayed.deprecated {
                        banner
                    }

                    if let desc = displayed.desc, !desc.isEmpty {
                        Text(desc)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let url = displayed.homepageURL {
                        Link(destination: url) {
                            Label(url.host() ?? "Homepage", systemImage: "safari")
                        }
                        // Links get the pointing hand; nothing else in the app does.
                        .pointerStyle(.link)
                        .accessibilityLabel("Open the \(displayed.title) homepage")
                    }

                    if let text = displayed.resolvedCaveats(prefix: model.client.prefix), !text.isEmpty {
                        caveats(text)
                    }

                    if !displayed.commands.isEmpty {
                        Divider()
                        commands
                    }

                    if !displayed.conflicts.isEmpty {
                        Divider()
                        conflicts
                    }

                    if !deps.isEmpty {
                        Divider()
                        related("Dependencies", packages: deps)
                    }

                    if !requiredBy.isEmpty {
                        Divider()
                        related("Required by", packages: requiredBy)
                    }

                    if let operation = model.latestOperation(for: displayed) {
                        Divider()
                        log(operation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: height(hasSections: !deps.isEmpty || !requiredBy.isEmpty || hasDetails))
        // Escape closes it. A sheet is window-modal on macOS, so clicking outside is not a
        // dismissal the platform offers — Escape and Done are.
        .onExitCommand { dismiss() }
    }

    /// Caveats, commands and conflicts fill the sheet the same way the related lists do, so they
    /// earn the taller frame too — everything past it scrolls.
    private var hasDetails: Bool {
        displayed.caveats?.isEmpty == false || !displayed.commands.isEmpty || !displayed.conflicts.isEmpty
    }

    private func height(hasSections: Bool) -> CGFloat {
        if model.latestOperation(for: displayed) != nil { return 580 }
        return hasSections ? 520 : 380
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PackageIconView(package: displayed, size: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayed.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    kindTag
                    // For casks the title is the display name, so the token is still worth showing.
                    if displayed.displayName != nil {
                        Text(displayed.name)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }

                versionLine

                if let installs = displayed.installs90d {
                    Label("\(installs.formatted(.number)) installs (90 days)", systemImage: "chart.bar")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(installs.formatted(.number)) installs in the last 90 days")
                }

                if let license = displayed.licenseLabel {
                    Label(license, systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel("License \(license)")
                }
            }
            .font(.subheadline)

            Spacer(minLength: 8)

            action
                .padding(.top, 2)
        }
    }

    private var kindTag: some View {
        TagLabel(displayed.kindLabel).font(.caption)
    }

    @ViewBuilder
    private var versionLine: some View {
        switch model.status(for: displayed) {
        case let .outdated(installed, current):
            HStack(spacing: 6) {
                Text("\(installed.shortVersion) → \(current.shortVersion)")
                    .foregroundStyle(.orange)
                if isPinned {
                    Text("pinned")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case let .installed(version):
            Text("Version \(version.shortVersion) installed")
                .foregroundStyle(.secondary)
        case .notInstalled, .busy:
            if !displayed.version.isEmpty {
                Text("Version \(displayed.version.shortVersion)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var action: some View {
        switch model.status(for: displayed) {
        case .busy:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(displayed.title) is being worked on")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(displayed.title) is installed")
        case .outdated:
            Button("Update") { model.upgrade(displayed) }
                .buttonStyle(.borderedProminent)
                .disabled(isPinned)
                .help(isPinned
                      ? "This package is pinned in Homebrew. Brewery never changes pins."
                      : "Update \(displayed.title)")
                .accessibilityLabel("Update \(displayed.title)")
        case .notInstalled:
            Button("Install") { model.install(displayed) }
                .buttonStyle(.borderedProminent)
                .disabled(displayed.disabled)
                .help(displayed.disabled
                      ? "Homebrew has disabled this package, so it can no longer be installed."
                      : "Install \(displayed.title)")
                .accessibilityLabel("Install \(displayed.title)")
        }
    }

    private var isPinned: Bool {
        model.outdated[displayed.id]?.pinned == true
    }

    // MARK: - Banner

    /// A disabled package's button is greyed out; this is where that gets explained.
    private var banner: some View {
        let isDisabled = displayed.disabled
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(isDisabled ? "Disabled" : "Deprecated")
                    .fontWeight(.semibold)
                Text(isDisabled
                     ? "Homebrew has disabled this package, so it can no longer be installed."
                     : "Homebrew no longer maintains this package. It still installs today, but it may be disabled in a future release.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: isDisabled ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isDisabled ? .red : .orange)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDisabled ? Color.red.opacity(0.1) : Color.orange.opacity(0.1),
                    in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Caveats, commands, conflicts

    /// Homebrew prints these after an install; the paths and commands in them are meant to be
    /// copied, hence the selectable text.
    private func caveats(_ text: String) -> some View {
        GroupBox {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Caveats", systemImage: "info.circle")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    /// The executables the formula puts on `PATH`, as one copyable list — a word list, not chips.
    private var commands: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Commands")

            Text(displayed.commands.joined(separator: " · "))
                .font(.callout)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Formulae that cannot be installed alongside this one. Each name is a row like a dependency,
    /// so following one retargets the sheet; a name the catalog does not cover stays plain text.
    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Conflicts with")

            ForEach(displayed.conflicts, id: \.name) { conflict in
                if let package = model.package(for: Package.packageID(kind: .formula, name: conflict.name)) {
                    RelatedRow(package: package,
                               version: model.installed[package.id]?.versions.last,
                               detail: conflict.reason) {
                        displayed = package
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conflict.name)
                        if let reason = conflict.reason, !reason.isEmpty {
                            Text(reason)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.bottom, 2)
    }

    // MARK: - Dependencies

    /// The receipt's runtime dependencies, in receipt order — `declared_directly` ones lead, and
    /// that ordering is information, so it is never re-sorted. Receipts list formulae only, and an
    /// entry that resolves to nothing (uninstalled since, or a tap the catalog misses) is dropped.
    private var dependencies: [Package] {
        guard let info = model.installed[displayed.id] else { return [] }
        return info.dependencies.compactMap {
            model.package(for: Package.packageID(kind: .formula, name: $0))
        }
    }

    /// The other side of the same map: for a keg that is only on disk as somebody else's
    /// dependency, this is the explanation.
    private var dependents: [Package] {
        guard model.installed[displayed.id] != nil else { return [] }
        return (model.dependents[displayed.id] ?? []).compactMap(model.package(for:))
    }

    private func related(_ title: String, packages: [Package]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(title)

            ForEach(packages) { item in
                RelatedRow(package: item, version: model.installed[item.id]?.versions.last) {
                    displayed = item
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Log

    private func log(_ operation: BrewOperation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: operation.symbolName)
                Text(operation.title)
                    .fontWeight(.medium)
                Spacer()
                Text(Self.description(of: operation.state))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)

            OperationLogView(operation: operation)
                .frame(height: 180)
        }
    }

    private static func description(of state: BrewOperation.State) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// One dependency or dependent: a real button, so it is reachable by keyboard and VoiceOver rather
/// than being a tap target only a mouse can find.
private struct RelatedRow: View {
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
