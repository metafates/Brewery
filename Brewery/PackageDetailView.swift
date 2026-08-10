//
//  PackageDetailView.swift
//  Brewery
//

import AppKit
import SwiftUI

/// The sheet behind a card: everything the grid had no room for — the full description, why an
/// action may be unavailable, where the package comes from, what it pulled in (and what pulled it
/// in), and the log of the last operation that touched it.
struct PackageDetailView: View {
    let package: Package

    /// The pages pushed above `package` by dependency/conflict rows. Following the graph is a
    /// drill-down, so it gets real navigation: back returns exactly the way you came, and each
    /// page opens at the top. Manual rather than `NavigationStack` — this sheet is a custom
    /// fixed-size surface (own footer, content-derived height, focus hacks) that framework
    /// navigation chrome would fight.
    @State private var stack: [Package] = []
    @State private var swipeBack = SwipeBackMonitor()
    /// Parked here around navigation: when the back button vanishes with its bar, focus would
    /// otherwise jump into the revealed page and AppKit would auto-scroll to the focused control
    /// — silently destroying the very scroll position the stack preserves.
    @FocusState private var rootFocused: Bool

    private var displayed: Package { stack.last ?? package }
    private var pages: [Package] { [package] + stack }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(package: Package) {
        self.package = package
    }

    private func push(_ item: Package) {
        guard item.id != displayed.id else { return }
        rootFocused = true
        withAnimation(.smooth(duration: 0.3)) { stack.append(item) }
    }

    private func pop() {
        guard !stack.isEmpty else { return }
        rootFocused = true
        withAnimation(.smooth(duration: 0.3)) { _ = stack.removeLast() }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !stack.isEmpty {
                backBar
            }

            // Every page in the drill-down stays mounted: the top page covers its parent, and
            // going back reveals the parent exactly as it was left — scroll position included.
            // Identity is the stack slot, so revisiting a package deeper down never collides.
            ZStack {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    DetailPage(pkg: item, onPush: { push($0) })
                        .opacity(index == pages.count - 1 ? 1 : 0)
                        .offset(x: index == pages.count - 1 ? 0 : -60)
                        // Disabled, not just hit-test-blocked: a hidden page's controls must not
                        // sit in the Tab order, and focus wandering into one auto-scrolls it.
                        .disabled(index != pages.count - 1)
                        .accessibilityHidden(index != pages.count - 1)
                        .zIndex(Double(index))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // The content only — the footer stays crisp and usable: a refresh never blocks Done.
            .refreshVeil(model.isRefreshing)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                // Left of Done, and not prominent: Done is the default action, and two filled
                // buttons side by side would leave neither reading as the one Return triggers.
                openAction
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        // The sheet gives initial focus to the first focusable thing it finds, and neither
        // `defaultFocus` nor assigning `@FocusState` outranks it. So the content itself takes that
        // focus and draws nothing for it: the sheet opens with no ring anywhere, and Tab from there
        // walks the real controls, which keep theirs.
        .focusable()
        .focusEffectDisabled()
        .focused($rootFocused)
        // The App Store gesture: a two-finger swipe right goes back. Installed as an event
        // monitor because SwiftUI has no swipe-navigation and the vertical ScrollView ignores
        // horizontal deltas anyway.
        .onAppear { swipeBack.install { pop() } }
        .onDisappear { swipeBack.remove() }
        .frame(width: 520, height: height(hasSections: hasRelated || hasDetails))
        // Escape closes it. A sheet is window-modal on macOS, so clicking outside is not a
        // dismissal the platform offers — Escape and Done are.
        .onExitCommand { dismiss() }
    }

    /// Caveats, commands, contents and conflicts fill the sheet the same way the related lists
    /// do, so they earn the taller frame too — everything past it scrolls.
    private var hasDetails: Bool {
        displayed.caveats?.isEmpty == false || !displayed.commands.isEmpty
            || !displayed.artifacts.isEmpty || !displayed.conflicts.isEmpty
            || displayed.service != nil
    }

    /// Whether the top page will show Dependencies/Required-by. Approximate on purpose: the
    /// receipt can name deps that resolve to nothing, and that near-miss only costs a slightly
    /// taller sheet.
    private var hasRelated: Bool {
        !(model.installed[displayed.id]?.dependencies.isEmpty ?? true)
            || !(model.dependents[displayed.id] ?? []).isEmpty
    }

    private func height(hasSections: Bool) -> CGFloat {
        if model.latestOperation(for: displayed) != nil { return 580 }
        return hasSections ? 520 : 380
    }

    // MARK: - Navigation

    /// Named, not just a chevron: "‹ openssl@3" says exactly where back leads. ⌘[ is the
    /// platform's Go Back; Escape keeps closing the sheet — the existing contract.
    private var backBar: some View {
        HStack {
            Button {
                pop()
            } label: {
                Label(stack.count >= 2 ? stack[stack.count - 2].title : package.title,
                      systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }


    /// The `.app` bundles this cask put on disk and that are still there. Resolved on each pass
    /// rather than cached: an app dragged to the Trash should stop being offered.
    private var launchable: [URL] {
        (model.installed[displayed.id]?.apps ?? []).compactMap(Receipts.appURL(named:))
    }

    /// Handed to LaunchServices, which starts the app as its own process — nothing is spawned as a
    /// child of Brewery, so quitting Brewery leaves it running.
    private func open(_ app: URL) {
        Task { _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
    }

    @ViewBuilder
    private var openAction: some View {
        if launchable.count == 1, let app = launchable.first {
            Button("Open") { open(app) }
                .help("Open \(app.deletingPathExtension().lastPathComponent)")
        } else if launchable.count > 1 {
            // A handful of casks ship more than one bundle; let the user say which.
            Menu("Open") {
                ForEach(launchable, id: \.self) { app in
                    Button(app.deletingPathExtension().lastPathComponent) { open(app) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// One page of the sheet's drill-down. A separate view on purpose: every mounted page renders
/// *its* package — during a slide the outgoing page must keep showing what it showed, and a
/// parent kept alive underneath must keep its own scroll offset.
private struct DetailPage: View {
    let pkg: Package
    let onPush: (Package) -> Void

    @Environment(AppModel.self) private var model
    @State private var showLicenses = false

    var body: some View {
        // Resolved once per pass: both lists were read three times each (the `isEmpty` guards,
        // the rows), rebuilding the same arrays every time.
        let deps = dependencies
        let requiredBy = dependents

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if pkg.disabled || pkg.deprecated {
                    banner
                }

                if let desc = pkg.desc, !desc.isEmpty {
                    Text(desc)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if pkg.homepageURL != nil || pkg.rubySourceURL != nil {
                    HStack(spacing: 16) {
                        if let url = pkg.homepageURL {
                            Link(destination: url) {
                                Label(url.host() ?? "Homepage", systemImage: "safari")
                            }
                            .accessibilityLabel("Open the \(pkg.title) homepage")
                        }
                        // The .rb file this package is defined by, on GitHub. Labelled with the
                        // file name: "wget.rb" says exactly what will open. Same face as the
                        // homepage link — two links in one row speak with one voice, and the
                        // </> glyph already says "code"; a font switch would read as a glitch.
                        if let source = pkg.rubySourceURL,
                           let file = pkg.rubySourceFileName {
                            Link(destination: source) {
                                Label(file, systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            .accessibilityLabel("Open the \(pkg.title) definition source")
                        }
                    }
                    // Links get the pointing hand; nothing else in the app does.
                    .pointerStyle(.link)
                }

                if let text = pkg.resolvedCaveats(prefix: model.client.prefix), !text.isEmpty {
                    Divider()
                    caveats(text)
                }

                if !pkg.commands.isEmpty {
                    Divider()
                    commands
                }

                if !pkg.artifacts.isEmpty {
                    Divider()
                    contents
                }

                if let service = pkg.service {
                    Divider()
                    serviceSection(service)
                }

                if !pkg.conflicts.isEmpty {
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

                if let operation = model.latestOperation(for: pkg) {
                    Divider()
                    log(operation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    // MARK: - Header

    private var header: some View {
        // Centered, not top-aligned: the v4 tap row made the info column taller than the icon,
        // and a top-pinned icon reads off-center against the stat rows. Centering is also right
        // when the column is the *shorter* one (a minimal package's three lines).
        HStack(alignment: .center, spacing: 16) {
            PackageIconView(package: pkg, size: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(pkg.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    kindTag
                    // For casks the title is the display name, so the token is still worth showing.
                    if pkg.displayName != nil {
                        Text(pkg.name)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }

                statRow("tag") { versionLine }

                if let installs = pkg.installs90d {
                    statRow("chart.bar") {
                        Text("\(installs.formatted(.number)) installs (90 days)")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(installs.formatted(.number)) installs in the last 90 days")
                }

                if let license = pkg.licenseLabel {
                    statRow("doc.text") {
                        licenseLine(license)
                    }
                }

                // Every package answers "which tap is this from" — core items included, so the
                // row is a constant of the sheet, not a third-party oddity.
                statRow("spigot") {
                    Text(tapLabel)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityLabel("From the \(tapLabel) tap")
            }
            .font(.subheadline)

            Spacer(minLength: 8)

            action
        }
    }

    private var kindTag: some View {
        TagLabel(pkg.kindLabel).font(.caption)
    }

    /// bun's expression is nine licenses long — five wrapped lines that dwarf the header. Past
    /// the threshold the row collapses to the first license plus a disclosure ("and 8 more")
    /// whose popover lists them one per row: summary in place, detail on demand, the anchored
    /// spring for free.
    @ViewBuilder private func licenseLine(_ license: String) -> some View {
        let components = pkg.licenseComponents
        if components.count > 1, license.count > 40, let first = components.first {
            HStack(spacing: 4) {
                Text("License: \(first)")
                    .foregroundStyle(.secondary)
                Button("and \(components.count - 1) more") {
                    showLicenses = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .popover(isPresented: $showLicenses, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Licenses")
                            .font(.headline)
                        ForEach(components, id: \.self) { component in
                            Text(component)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(14)
                    .frame(minWidth: 220, alignment: .leading)
                }
            }
            // No .combine here: merging would swallow the button and VoiceOver could never
            // activate it. Read separately it is "License: MIT", then "and 8 more, button".
        } else {
            // Prefixed rather than suffixed: "MIT License" reads well but "GPL-3.0-or-later
            // License" does not, and SPDX identifiers are mostly the latter shape.
            Text("License: \(license)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("License \(license)")
        }
    }

    /// One header stat. The glyph sits in a fixed-width column so the values line up down the
    /// list — `chart.bar` and `doc.text` are not the same width, so `Label` alone leaves them ragged.
    private func statRow(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            content()
        }
    }

    @ViewBuilder
    private var versionLine: some View {
        switch model.status(for: pkg) {
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
            if !pkg.version.isEmpty {
                Text("Version \(pkg.version.shortVersion)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var action: some View {
        switch model.status(for: pkg) {
        case .busy:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(pkg.title) is being worked on")
        case .installed:
            Label {
                Text("Installed").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .accessibilityLabel("\(pkg.title) is installed")
        case .outdated:
            Button("Update") { model.upgrade(pkg) }
                .buttonStyle(.borderedProminent)
                .disabled(isPinned)
                .help(isPinned
                      ? "This package is pinned in Homebrew. Brewery never changes pins."
                      : "Update \(pkg.title)")
                .accessibilityLabel("Update \(pkg.title)")
        case .notInstalled:
            // The trust disclosure: installing a tap item makes brew trust it persistently, and
            // that should not happen silently on a click.
            VStack(alignment: .trailing, spacing: 4) {
                Button("Install") { model.install(pkg) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pkg.disabled)
                    .help(installHelp)
                    .accessibilityLabel("Install \(pkg.title)")
                if !pkg.disabled, let tap = model.effectiveTap(for: pkg) {
                    Text("Trusts \(tap)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Installing tells Homebrew to trust \(tap)/\(pkg.name) permanently.")
                }
            }
        }
    }

    private var installHelp: String {
        if pkg.disabled {
            return "Homebrew has disabled this package, so it can no longer be installed."
        }
        if let tap = model.effectiveTap(for: pkg) {
            return "Install \(pkg.title) — Homebrew will trust \(tap)/\(pkg.name) permanently."
        }
        return "Install \(pkg.title)"
    }

    private var isPinned: Bool {
        model.outdated[pkg.id]?.pinned == true
    }

    /// The effective tap (receipt over catalog), falling back to the core tap the kind implies.
    private var tapLabel: String {
        model.effectiveTap(for: pkg) ?? pkg.tapLabel
    }

    // MARK: - Banner

    /// A disabled package's button is greyed out; this is where that gets explained.
    private var banner: some View {
        let isDisabled = pkg.disabled
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

    /// Homebrew prints these after an install, and they follow conventions worth honoring:
    /// backticks mean inline code, two-space-indented lines are commands and paths, blank lines
    /// separate paragraphs. Rendered as such — prose with real code spans, indented runs as
    /// copyable code blocks — instead of the undifferentiated slab a single `Text` makes.
    /// A plain section like Commands and Dependencies, not a `GroupBox`: the box indented its
    /// label off the shared margin, and its container doubled the code blocks' own chips.
    private func caveats(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Caveats")

            ForEach(Array(CaveatFormat.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let paragraph):
                    // AppKit-backed on purpose: links get the pointing hand over exactly
                    // the link (and open on click) — per-run cursors are beyond SwiftUI Text.
                    RichText(text: CaveatFormat.attributed(paragraph))
                case .code(let code):
                    codeBlock(code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One indented run — commands meant to be executed, so they come with a copy button.
    private func codeBlock(_ code: String) -> some View {
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

    /// The executables the formula puts on `PATH`, as one copyable list — a word list, not chips.
    private var commands: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Commands")

            Text(pkg.commands.joined(separator: " · "))
                .font(.callout)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the cask puts on the machine — the payload counterpart of a formula's Commands.
    /// A two-column grid: kind (icon + label) on the left, names on the right, so several kinds
    /// (app, commands, installer…) read as one aligned table rather than stacked fragments.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Contents")

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
                ForEach(pkg.artifacts, id: \.kind) { artifact in
                    GridRow {
                        Label(label(for: artifact), systemImage: artifact.kind.symbol)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(names(for: artifact))
                            .fontDesign(artifact.kind.isMonospaced ? .monospaced : nil)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(for artifact: CaskArtifact) -> String {
        artifact.kind == .app && artifact.names.count > 1 ? "Apps" : artifact.kind.label
    }

    /// Apps read as products, not files — ".app" is dropped. Fonts collapse to a count: a font
    /// cask is one typeface shipped as many weight files, and listing twelve `.ttf` names says
    /// less than "12 font files". Everything else is the `·`-joined list the Commands section
    /// already taught.
    private func names(for artifact: CaskArtifact) -> String {
        switch artifact.kind {
        case .app, .suite:
            return artifact.names
                .map { $0.hasSuffix(".app") ? String($0.dropLast(".app".count)) : $0 }
                .joined(separator: " · ")
        case .font:
            return artifact.names.count == 1
                ? artifact.names[0]
                : "\(artifact.names.count) font files"
        default:
            return artifact.names.joined(separator: " · ")
        }
    }

    /// The formula's background service: the toggle when it is installed, then the definition in
    /// the same two-column grid Contents uses. What it runs, when, where it listens, where it logs.
    private func serviceSection(_ service: ServiceDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Service")

            // A switch must terminate a labeled row (System Settings' grammar) — floating beside
            // the section title it reads as decoration. The label is the live state, so the row
            // says exactly what the switch flips.
            if model.installed[pkg.id] != nil {
                HStack(spacing: 8) {
                    ServiceStatusLabel(package: pkg, quietLabel: "Not running")
                        .font(.callout)
                    Spacer()
                    ServiceToggle(package: pkg)
                }
                .padding(.bottom, 4)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
                if !service.run.isEmpty {
                    serviceRow("Command", symbol: "terminal") {
                        Text(service.run
                            .map { Package.substitutingPrefix($0, prefix: model.client.prefix) }
                            .joined(separator: " "))
                            .fontDesign(.monospaced)
                    }
                }
                serviceRow("Schedule", symbol: "clock.arrow.circlepath") {
                    Text(service.scheduleLabel)
                }
                if !service.ports.isEmpty {
                    serviceRow("Ports", symbol: "network") {
                        Text(service.ports.joined(separator: " · "))
                            .fontDesign(.monospaced)
                    }
                }
                if let logPath = service.logPath {
                    serviceRow("Logs", symbol: "text.alignleft") {
                        Text(Package.substitutingPrefix(logPath, prefix: model.client.prefix))
                            .fontDesign(.monospaced)
                    }
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serviceRow(_ label: String, symbol: String,
                            @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            content()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Formulae that cannot be installed alongside this one. Each name is a row like a dependency,
    /// so following one retargets the sheet; a name the catalog does not cover stays plain text.
    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Conflicts with")

            ForEach(pkg.conflicts, id: \.name) { conflict in
                if let package = model.package(for: Package.packageID(kind: .formula, name: conflict.name)) {
                    RelatedRow(package: package,
                               version: model.installed[package.id]?.versions.last,
                               detail: conflict.reason) {
                        onPush(package)
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
        guard let info = model.installed[pkg.id] else { return [] }
        return info.dependencies.compactMap {
            model.package(for: Package.packageID(kind: .formula, name: $0))
        }
    }

    /// The other side of the same map: for a keg that is only on disk as somebody else's
    /// dependency, this is the explanation.
    private var dependents: [Package] {
        guard model.installed[pkg.id] != nil else { return [] }
        return (model.dependents[pkg.id] ?? []).compactMap(model.package(for:))
    }

    private func related(_ title: String, packages: [Package]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(title)

            ForEach(packages) { item in
                RelatedRow(package: item, version: model.installed[item.id]?.versions.last) {
                    onPush(item)
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

/// Splits a caveat into its conventional blocks: prose paragraphs and indented command runs.
/// Pure and line-based — brew's caveats are hand-written text, not real Markdown, so the only
/// structure worth trusting is the one every formula actually uses.
nonisolated enum CaveatFormat {
    enum Block: Equatable {
        case text(String)
        case code(String)
    }

    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var textLines: [String] = []
        var codeLines: [String] = []

        func flushText() {
            let paragraph = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { blocks.append(.text(paragraph)) }
            textLines = []
        }
        func flushCode() {
            guard !codeLines.isEmpty else { return }
            // Strip the common indent; what remains is what the user would type.
            let indent = codeLines.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            blocks.append(.code(codeLines.map { String($0.dropFirst(indent)) }.joined(separator: "\n")))
            codeLines = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let isIndented = line.hasPrefix("  ") || line.hasPrefix("\t")
            if isBlank {
                flushText()
                flushCode()
            } else if isIndented {
                flushText()
                codeLines.append(line)
            } else {
                flushCode()
                textLines.append(line)
            }
        }
        flushText()
        flushCode()
        return blocks
    }

    /// A prose paragraph, dressed: inline Markdown (inline-only — full parsing would collapse the
    /// newlines the text depends on; failure falls back to the raw string), code spans tinted so
    /// mono-heavy prose stops reading as noise, and bare URLs linkified — caveats cite docs pages
    /// as plain text.
    static func attributed(_ paragraph: String) -> NSAttributedString {
        let markdown = (try? AttributedString(
            markdown: paragraph,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(paragraph)

        let result = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
        let whole = NSRange(location: 0, length: result.length)
        let baseFont = NSFont.preferredFont(forTextStyle: .callout)
        result.addAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: whole)

        // Code spans: the mono face plus a quiet chip, matching the code blocks' language.
        var offset = 0
        for run in markdown.runs {
            let length = markdown[run.range].characters.count
            if run.inlinePresentationIntent?.contains(.code) == true {
                let range = NSRange(location: offset, length: length)
                result.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
                    .backgroundColor: NSColor.quaternarySystemFill,
                ], range: range)
            }
            offset += length
        }

        // Bare URLs become real links (where Markdown didn't already make one).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: result.string, range: whole) {
                guard let url = match.url,
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil
                else { continue }
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }
}

/// An AppKit-backed rich label: a selectable `NSTextField` gives links the pointing hand over
/// exactly the link and opens them on click — the Mail/Notes behavior SwiftUI `Text` cannot
/// reproduce, because pointer styles there are per-view, never per-run.
private struct RichText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true
        // Without this a selectable label flattens its attributes on selection and links go dead.
        field.allowsEditingTextAttributes = true
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        nsView.preferredMaxLayoutWidth = width
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let size = nsView.cell?.cellSize(forBounds: bounds) ?? .zero
        return CGSize(width: width, height: ceil(size.height))
    }
}

/// Copies and says so: the glyph swaps to a checkmark for a beat — a silent copy button leaves
/// the user wondering whether anything happened.
private struct CopyButton: View {
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

/// The App Store back gesture: a mostly-horizontal two-finger swipe to the right pops a page.
/// A local scroll-event monitor because SwiftUI has no swipe navigation; the sheet's vertical
/// ScrollView ignores horizontal deltas, so nothing is stolen from scrolling. Fires once per
/// gesture (latched until the fingers lift) and respects the system's swipe-navigation setting.
/// ponytail: threshold-triggered with the standard slide, not finger-tracked; the upgrade path
/// is `NSEvent.trackSwipeEvent` driving interactive progress.
@MainActor
final class SwipeBackMonitor {
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var latched = false
    private var lastEvent: TimeInterval = 0

    func install(_ back: @escaping () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event, back: back)
            return event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, back: () -> Void) {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return }

        if event.phase == .began || event.timestamp - lastEvent > 0.3 {
            // A new gesture — either launchd-real (phases) or synthetic (a stale-time reset).
            accumulated = 0
            latched = false
        }
        lastEvent = event.timestamp
        if event.phase == .ended || event.phase == .cancelled {
            accumulated = 0
            return
        }

        // Mostly-horizontal only: diagonal scrolling of the page must never navigate.
        guard !latched, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        accumulated += event.scrollingDeltaX
        if accumulated > 80 {
            latched = true
            back()
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
