//
//  PackageDetailView.swift
//  Brewery
//

import AppKit
import SwiftUI

/// The inspector beside the grid: everything the cards had no room for — the full description, why
/// an action may be unavailable, where the package comes from, what it pulled in (and what pulled
/// it in), and the log of the last operation that touched it.
///
/// A pane rather than a sheet, because reading about a package is not a task to be completed or
/// abandoned: the grid stays live and clickable underneath, the pane resizes with the window, and
/// clicking the next card just moves the pane on. As a modal it had grown its own footer, its own
/// back button, its own swipe-back gesture and three hardcoded heights — an app inside the app.
struct PackageDetailView: View {
    let package: Package

    /// One entry in the pane's drill-down: another package's page, (v13) a package's full
    /// command list, or (v14) a tap's package list.
    enum Page {
        case package(Package)
        case commands(Package)
        case tap(String)

        var id: String {
            switch self {
            case .package(let package): package.id
            case .commands(let package): "\(package.id)/commands"
            case .tap(let tap): "tap:\(tap)"
            }
        }

        /// What the back bar calls this page when it is the one beneath the top.
        var title: String {
            switch self {
            case .package(let package): package.title
            case .commands: "Commands"
            case .tap(let tap): tap
            }
        }
    }

    /// The pages pushed above `package` by dependency/conflict rows. Following the graph is a
    /// drill-down, so it gets real navigation: back returns exactly the way you came, and each
    /// page opens at the top. Manual rather than `NavigationStack`: pages stay mounted so back
    /// restores the parent's scroll offset, and a stack inside a pane has no toolbar for the
    /// framework to hang a back button from anyway.
    @State private var stack: [Page] = []

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayed: Page { stack.last ?? .package(package) }
    private var pages: [Page] { [.package(package)] + stack }

    private func push(_ page: Page) {
        guard page.id != displayed.id else { return }
        withAnimation(.smooth(duration: 0.3)) { stack.append(page) }
    }

    private func pop() {
        guard !stack.isEmpty else { return }
        withAnimation(.smooth(duration: 0.3)) { _ = stack.removeLast() }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !stack.isEmpty {
                backBar
                Divider()
            }
            // Every page in the drill-down stays mounted: the top page covers its parent, and
            // going back reveals the parent exactly as it was left — scroll position included.
            // Identity is the stack slot, so revisiting a package deeper down never collides.
            ZStack {
                ForEach(pages.enumerated(), id: \.offset) { index, item in
                    Group {
                        switch item {
                        case .package(let package):
                            DetailPage(package: package, onPush: { push($0) })
                        case .commands(let package):
                            CommandsPage(package: package)
                        case .tap(let tap):
                            TapPage(tap: tap, onPush: { push($0) })
                        }
                    }
                    .opacity(index == pages.count - 1 ? 1 : 0)
                        .offset(x: offset(for: index))
                        // Disabled, not just hit-test-blocked: a hidden page's controls must not
                        // sit in the Tab order, and focus wandering into one auto-scrolls it.
                        .disabled(index != pages.count - 1)
                        .accessibilityHidden(index != pages.count - 1)
                        .zIndex(Double(index))
                        .transition(pushTransition)
                }
            }
            // v24 — the veil moved up to ContentView's inspector container: applied once for
            // both the selected and the No Selection branch, capsule-less (one wait, one
            // narrator — the content column's capsule).
        }
        // v15.2 — re-selecting this package's own card while drilled into a subpage pops the
        // stack home. The pane's `.id(package.id)` only resets when the selection *changes*;
        // without this, clicking the shown package's card answered with nothing.
        .onChange(of: model.selectionRequests) {
            guard !stack.isEmpty else { return }
            withAnimation(.smooth(duration: 0.3)) { stack.removeAll() }
        }
        // View ▸ Back's channel (the model routes it here only while no tap page is open),
        // and the published depth that enables the menu item.
        .onChange(of: model.backRequests) { pop() }
        .onChange(of: stack.count, initial: true) { model.paneDepth = stack.count }
        .onDisappear { model.paneDepth = 0 }
    }

    /// Navigation at the leading top edge, which is where macOS puts a way back. It sat in a footer
    /// while this was a fixed-size sheet, because a bar that came and went skewed a layout whose
    /// height was derived from its content — a pane that fills its column has no such height.
    private var backBar: some View {
        HStack {
            Button {
                pop()
            } label: {
                Label(pages[pages.count - 2].title, systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .help("Back")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .transition(.opacity)
    }

    private func offset(for index: Int) -> CGFloat {
        guard !reduceMotion, index != pages.count - 1 else { return 0 }
        return -60
    }

    private var pushTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }
}

/// One page of the sheet's drill-down. A separate view on purpose: every mounted page renders
/// *its* package — during a slide the outgoing page must keep showing what it showed, and a
/// parent kept alive underneath must keep its own scroll offset.
private struct DetailPage: View {
    let package: Package
    let onPush: (PackageDetailView.Page) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        // Resolved once per pass: both lists were read three times each (the `isEmpty` guards,
        // the rows), rebuilding the same arrays every time.
        let deps = dependencies
        let requiredBy = dependents

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(package: package, onPush: onPush)

                if package.disabled || package.deprecated {
                    banner
                }

                if let desc = package.desc, !desc.isEmpty {
                    Text(desc)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if package.homepageURL != nil || package.rubySourceURL != nil {
                    HStack(spacing: 16) {
                        // "Homepage", not the bare host: the App Store labels this link
                        // generically too ("Developer Website"), a long domain has no good
                        // wrap at 300 pt, and a lowercase literal beside "Recipe" mixed two
                        // grammars in one row. The destination survives in the tooltip —
                        // and the word matches the card context menu's "Open Homepage".
                        if let url = package.homepageURL {
                            Link(destination: url) {
                                // `globe`, not `safari`: the link opens the *default* browser,
                                // and Apple restricts the safari glyph to Safari itself.
                                Label("Homepage", systemImage: "globe")
                            }
                            .help(url.absoluteString)
                            .accessibilityLabel("Open the \(package.title) homepage")
                        }
                        // The .rb file this package is defined by, on GitHub. Labelled
                        // "Recipe" — brew's own frame (Formula Cookbook, Cask Cookbook):
                        // one plain word that says "the instructions brew installs this
                        // from" for both kinds. Not the file name (restated the token two
                        // rows up — it lives in the tooltip), not the kind (duplicated the
                        // header tag), and not "Source", which beside a homepage link reads
                        // as the app's own source code. Same face as the homepage link —
                        // two links in one row speak with one voice, and the </> glyph
                        // already says "code".
                        if let source = package.rubySourceURL,
                           let file = package.rubySourceFileName {
                            Link(destination: source) {
                                Label("Recipe", systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            .help("Open \(file) on GitHub")
                            .accessibilityLabel("Open the \(package.title) recipe")
                        }
                    }
                    // Links get the pointing hand; nothing else in the app does.
                    .pointerStyle(.link)
                }

                DetailBanner(package: package)

                DetailFontPreview(package: package)

                if let text = package.resolvedCaveats(prefix: model.client.prefix), !text.isEmpty {
                    Divider()
                    caveats(text)
                }

                if !package.commands.isEmpty {
                    Divider()
                    commands
                }

                if !package.artifacts.isEmpty {
                    Divider()
                    contents
                }

                if let service = package.service {
                    Divider()
                    serviceSection(service)
                }

                if !package.conflicts.isEmpty {
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

                if let operation = model.latestOperation(for: package) {
                    Divider()
                    log(operation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    // MARK: - Banner

    /// A disabled package's button is greyed out; this is where that gets explained.
    /// v11 — specific, not generic: why brew retired it (brew's own reason vocabulary), since
    /// when, when it stops working, and what replaces it. The replacement is the pane's usual
    /// tappable row, kept *outside* the texts' `.combine` — folding a button into a combined
    /// element hides it from VoiceOver (the service Logs row's lesson).
    private var banner: some View {
        let isDisabled = package.disabled
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isDisabled ? "Disabled" : "Deprecated")
                        .fontWeight(.semibold)
                    Text(package.deprecationExplanation
                         ?? "Homebrew no longer maintains this package.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                if let id = package.replacementID, let replacement = model.package(for: id) {
                    RelatedRow(package: replacement,
                               version: model.installed[replacement.id]?.versions.last,
                               detail: "Recommended replacement") {
                        onPush(.package(replacement))
                    }
                    .padding(.top, 4)
                } else if let name = package.replacementName {
                    // brew names a successor the catalog doesn't cover — say it, don't row it.
                    Text("Recommended replacement: \(name)")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        } icon: {
            Image(systemName: isDisabled ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isDisabled ? .red : .orange)
                .accessibilityHidden(true)
        }
        .warningWash(isDisabled ? .red : .orange)
    }

    // MARK: - Caveats, commands, conflicts

    /// Homebrew prints these after an install, and they follow conventions worth honoring:
    /// backticks mean inline code, two-space-indented lines are commands and paths, blank lines
    /// separate paragraphs. Rendered as such — prose with real code spans, indented runs as
    /// copyable code blocks — instead of the undifferentiated slab a single `Text` makes.
    /// A plain section like Commands and Dependencies, not a `GroupBox`: the box indented its
    /// label off the shared margin, and its container doubled the code blocks' own chips.
    private func caveats(_ text: String) -> some View {
        let blocks = CaveatFormat.blocks(of: text)
        let mentioned = mentionedPackages(in: blocks)
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Caveats")

            ForEach(blocks.enumerated(), id: \.offset) { index, block in
                switch block {
                case .text(let paragraph):
                    // Native Text (v9): it renders the code chips and opens the link runs on
                    // click. This was an AppKit NSTextField for one refinement — the pointing
                    // hand over exactly the link, which SwiftUI has no per-run cursor for —
                    // and a whole NSViewRepresentable with a sizing workaround wasn't worth
                    // a cursor.
                    Text(CaveatFormat.attributed(paragraph))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    // v17 — a `brew install` the caveat asks for is a package this app can show:
                    // the catalog-resolved mentions ride directly under their block as the same
                    // navigation rows dependencies use. Install stays on the pushed page, where
                    // the one prominent Install button (and its consent flow) already lives.
                    VStack(alignment: .leading, spacing: 2) {
                        CodeChip(code: code)
                        ForEach(mentioned[index] ?? []) { item in
                            RelatedRow(package: item, version: model.installed[item.id]?.versions.last) {
                                onPush(.package(item))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Catalog resolution for the caveat's `brew install` mentions, keyed by block index.
    /// A bare name tries formula then cask — brew's own resolution order for `brew install` —
    /// while `--cask` pins the kind. The page's own package never gets a row (amazon-music's
    /// caveat reinstalls itself), but the filter is by full ID: the fontforge *formula*
    /// legitimately points at the fontforge *cask*. Unresolvable names (untapped taps, typos)
    /// stay plain text in the block, the same rule conflicts follow.
    private func mentionedPackages(in blocks: [CaveatFormat.Block]) -> [Int: [Package]] {
        var seen: Set<Package.ID> = [package.id]
        var result: [Int: [Package]] = [:]
        for (index, block) in blocks.enumerated() {
            guard case .code(let code) = block else { continue }
            let rows = CaveatFormat.installMentions(in: code).compactMap { mention -> Package? in
                let candidates = mention.isCask
                    ? [Package.packageID(kind: .cask, name: mention.name)]
                    : [Package.packageID(kind: .formula, name: mention.name),
                       Package.packageID(kind: .cask, name: mention.name)]
                guard let found = candidates.lazy.compactMap(model.package(for:)).first,
                      seen.insert(found.id).inserted else { return nil }
                return found
            }
            if !rows.isEmpty { result[index] = rows }
        }
        return result
    }

    /// v13 — a handful of commands reads inline as one copyable word list; past this the run
    /// is a wall (llvm ships 112 — the fonts lesson in prose form), so the section shows the
    /// count and the full list lives one page down the pane's own stack.
    private static let inlineCommandLimit = 8

    /// The executables the formula puts on `PATH`, as one copyable list — a word list, not chips.
    private var commands: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Commands")

            let commands = package.displayCommands
            if commands.count <= Self.inlineCommandLimit {
                Text(commands.joined(separator: " · "))
                    .font(.callout)
                    .monospaced()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The count as the disclosure's descriptive label (HIG *Disclosure controls*),
                // in RelatedRow's chrome; the Contents section's "12 font files" grammar.
                CommandsRow(count: commands.count) {
                    onPush(.commands(package))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the cask puts on the machine — the payload counterpart of a formula's Commands.
    /// A two-column grid: kind (icon + label) on the left, names on the right, so several kinds
    /// (app, commands, installer…) read as one aligned table rather than stacked fragments.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Contents")

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
                ForEach(package.artifacts, id: \.kind) { artifact in
                    gridRow(label(for: artifact), symbol: artifact.kind.symbol) {
                        Text(names(for: artifact))
                            .fontDesign(artifact.kind.isMonospaced ? .monospaced : nil)
                    }
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
            SectionTitle("Service")

            // A switch must terminate a labeled row (System Settings' grammar) — floating beside
            // the section title it reads as decoration. The label is the live state, so the row
            // says exactly what the switch flips.
            if model.installed[package.id] != nil {
                HStack(spacing: 8) {
                    ServiceStatusLabel(package: package, quietLabel: "Not running")
                        .font(.callout)
                    Spacer()
                    ServiceToggle(package: package)
                }
                .padding(.bottom, 4)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
                if !service.run.isEmpty {
                    gridRow("Command", symbol: "terminal") {
                        Text(service.run
                            .map { Package.substitutingPrefix($0, prefix: model.client.prefix) }
                            .joined(separator: " "))
                            .fontDesign(.monospaced)
                    }
                }
                gridRow("Schedule", symbol: "clock.arrow.circlepath") {
                    Text(service.scheduleLabel)
                }
                if !service.ports.isEmpty {
                    gridRow("Ports", symbol: "network") {
                        Text(service.ports.joined(separator: " · "))
                            .fontDesign(.monospaced)
                    }
                }
                if let logPath = service.logPath {
                    // v10 — a bespoke row, not `gridRow`: its `.combine` would swallow the
                    // open button (the license row's lesson). Console is the platform's log
                    // viewer; the button appears once the file exists — the app already has
                    // a log window, but that one tails *operations*, not service runtime.
                    GridRow {
                        Label("Logs", systemImage: "text.alignleft")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        HStack(spacing: 8) {
                            Text(Package.substitutingPrefix(logPath, prefix: model.client.prefix))
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = model.serviceLogURL(for: package) {
                                Button {
                                    model.openFile(at: url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Open the log in Console")
                                .accessibilityLabel("Open the \(package.title) log in Console")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridRow(_ label: String, symbol: String,
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

    /// Packages that cannot be installed alongside this one — formula conflicts with brew's
    /// reasons, cask conflicts (v10) as bare cask tokens. Each name is a row like a dependency,
    /// so following one retargets the sheet; a name the catalog does not cover stays plain text.
    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle("Conflicts with")

            ForEach(package.conflicts, id: \.name) { conflict in
                if let package = model.package(for: Package.packageID(kind: conflict.kind ?? .formula, name: conflict.name)) {
                    RelatedRow(package: package,
                               version: model.installed[package.id]?.versions.last,
                               detail: conflict.reason) {
                        onPush(.package(package))
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

    // MARK: - Dependencies

    /// The receipt's runtime dependencies, in receipt order — `declared_directly` ones lead, and
    /// that ordering is information, so it is never re-sorted. Receipts list formulae only, and an
    /// entry that resolves to nothing (uninstalled since, or a tap the catalog misses) is dropped.
    private var dependencies: [Package] {
        guard let info = model.installed[package.id] else { return [] }
        return info.dependencies.compactMap {
            model.package(for: Package.packageID(kind: .formula, name: $0))
        }
    }

    /// The other side of the same map: for a keg that is only on disk as somebody else's
    /// dependency, this is the explanation.
    private var dependents: [Package] {
        guard model.installed[package.id] != nil else { return [] }
        return (model.dependents[package.id] ?? []).compactMap(model.package(for:))
    }

    private func related(_ title: String, packages: [Package]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title)

            ForEach(packages) { item in
                RelatedRow(package: item, version: model.installed[item.id]?.versions.last) {
                    onPush(.package(item))
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
                Text(operation.state.label)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)

            OperationLogView(operation: operation)
                .frame(height: 180)
        }
    }
}


/// v13 — the Commands section's summary row when the run would be a wall: the count as the
/// descriptive label, the pane's row chrome (`PaneRow`, shared with `RelatedRow` since v24),
/// the drill-down as the disclosure.
private struct CommandsRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        PaneRow(title: "\(count) commands", action: action) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
        .accessibilityLabel("\(count) commands")
        .accessibilityHint("Shows the full command list")
        .help("Show all commands")
    }
}

/// v13 — the full command list, one per row: a scannable column where the inline run was a
/// wall. Lazy because texlive ships hundreds; selectable like the run it replaces.
private struct CommandsPage: View {
    let package: Package

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                SectionTitle("Commands")

                Text("^[\(package.displayCommands.count) executables](inflect: true) \(package.title) puts on your PATH.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                ForEach(package.displayCommands, id: \.self) { command in
                    Text(command)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// v14 — what a tap provides, one page down (the Commands page's grammar): RelatedRows so any
/// package is one click deeper. Bounded, the fonts law: past the shelf limit the page shows
/// the most-installed slice — the top of homebrew/core is a real answer, row 4 000 is not —
/// and a Browse All button hands the full walk to the Taps grid, the surface built for it.
/// Only the tap string crosses the view boundary — rows build here, into `@State`, per the
/// no-large-arrays-across-boundaries rule.
private struct TapPage: View {
    let tap: String
    let onPush: (PackageDetailView.Page) -> Void

    /// App Store's shelf grammar: a bounded sample plus See All. ~2.5 pane-screens of rows.
    private static let shelfLimit = 30

    @Environment(AppModel.self) private var model
    @State private var rows: [Package] = []
    @State private var total = 0
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                SectionTitle(tap)

                if loaded, rows.isEmpty {
                    // The Taps section's own sentence for the same fact.
                    Text("This tap has no packages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else if loaded {
                    Text(total > rows.count
                         ? "^[\(total) packages](inflect: true) this tap provides. Showing the \(rows.count) most installed."
                         : "^[\(rows.count) packages](inflect: true) this tap provides.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)

                    ForEach(rows) { item in
                        RelatedRow(package: item,
                                   version: model.installed[item.id]?.versions.last) {
                            onPush(.package(item))
                        }
                    }

                    if total > rows.count {
                        Button("Browse All in Taps") {
                            model.requestOpenTap(tap)
                        }
                        .padding(.top, 8)
                        .help("Show everything \(tap) provides in the Taps section")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task(id: tap) {
            var packages = model.packages(inTap: tap)
            total = packages.count
            if packages.count > Self.shelfLimit {
                // A cap is only honest if it keeps the most relevant rows: popularity, any tap.
                packages.sort(by: Package.popularityOrder)
                packages.removeSubrange(Self.shelfLimit...)
            } else {
                packages.sort(by: TapStore.coreTaps.contains(tap)
                              ? Package.popularityOrder : Package.displayOrder)
            }
            rows = packages
            loaded = true
        }
    }
}

// RelatedRow, CopyButton and CodeChip moved to SharedControls.swift (v19) — the Checkup
// report shares the pane's grammar for package rows and command chips.
