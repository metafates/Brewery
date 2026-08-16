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
    /// v9 — whether this pane's back button owns ⌘[. False while a tap page is showing: two
    /// live back stacks would both claim the shortcut and SwiftUI would pick one arbitrarily,
    /// so the content column — the primary navigation — wins (HIG Keyboards: don't create
    /// ambiguous shortcuts). The button itself stays clickable and focusable regardless.
    var ownsBackShortcut = true

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
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
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
            .refreshVeil(model.isRefreshing)
        }
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
            .keyboardShortcut(ownsBackShortcut ? KeyboardShortcut("[", modifiers: .command) : nil)
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
    @State private var showLicenses = false
    @State private var fontFaces: [FontPreview.Face] = []
    @State private var fontFacesDropped = 0
    @State private var diskBytes: Int64?
    @State private var sizeFailed = false

    /// Reserved while installed and measurable; collapses only if the measurement genuinely
    /// fails (a hand-deleted keg) — the rare case pays one reflow rather than every pane
    /// showing a permanent skeleton.
    private var showsSizeRow: Bool {
        model.installed[package.id] != nil && model.client.prefix != nil && !sizeFailed
    }

    private var sizeKey: String {
        DiskUsage.cacheKey(for: package.id, version: model.installed[package.id]?.versions.last)
    }
    @State private var bannerPhase = BannerPhase.absent

    /// v10.1 — the banner slot's lifecycle: reserved while the card is on its way, gone if it
    /// never arrives. Knowing the footprint up front is what makes the reservation honest.
    private enum BannerPhase: Equatable {
        case absent
        case loading
        case loaded(NSImage)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.absent, .absent), (.loading, .loading): true
            case let (.loaded(a), .loaded(b)): a === b
            default: false
            }
        }
    }

    var body: some View {
        // Resolved once per pass: both lists were read three times each (the `isEmpty` guards,
        // the rows), rebuilding the same arrays every time.
        let deps = dependencies
        let requiredBy = dependents

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

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
                                Label("Homepage", systemImage: "safari")
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

                // v10 — the repo's social-preview card as hero artwork, in the screenshots
                // slot. Not for fonts: their Preview section is strictly better artwork.
                // v10.1 — the slot is reserved while the card loads (HIG Loading: "show
                // something as soon as possible"; placeholders over spinners is the icon
                // grammar) and the image crossfades in — the pop-in reflow read as a glitch.
                Group {
                    switch bannerPhase {
                    case .absent:
                        EmptyView()
                    case .loading:
                        bannerPlaceholder
                    case .loaded(let image):
                        bannerView(image)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: bannerPhase)

                if !fontFaces.isEmpty {
                    Divider()
                    fontPreview
                }

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
        .task(id: installedTaskID) {
            (fontFaces, fontFacesDropped) = ([], 0)
            guard package.isFont, model.installed[package.id] != nil else { return }
            (fontFaces, fontFacesDropped) = await FontPreview.resolve(names: fontNames,
                                                                      limit: Self.faceLimit)
        }
        .task(id: installedTaskID) {
            sizeFailed = false
            diskBytes = nil
            guard model.installed[package.id] != nil else { return }
            // Roots come from the model — the same answer the size sort's sweep measures.
            let roots = model.sizeRoots(for: package)
            if !roots.isEmpty, let measured = await DiskUsage.measuredBytes(key: sizeKey, roots: roots) {
                diskBytes = measured
            } else {
                sizeFailed = true
            }
        }
        .task(id: package.id) {
            guard !package.isFont,
                  let source = IconStore.bannerSource(homepage: package.homepageURL) else {
                bannerPhase = .absent
                return
            }
            bannerPhase = .loading
            if let image = await IconStore.banners.image(key: source.key, url: source.url) {
                bannerPhase = .loaded(image)
            } else {
                // Offline or no card after all: collapse. The rare case pays one reflow
                // rather than every pane paying a permanent empty box.
                bannerPhase = .absent
            }
        }
    }

    /// The card's reserved footprint: GitHub renders og cards at 1200×600 (verified on the
    /// wire, not the og-spec's 1.91:1), so the slot is laid out at final size and the image
    /// replaces the quiet fill without a reflow.
    private var bannerPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary.opacity(0.5))
            .aspectRatio(2, contentMode: .fit)
            .accessibilityHidden(true)
    }

    /// GitHub's cards are 2:1-ish; full pane width, its own corner radius, and a hairline —
    /// a white-background banner otherwise bleeds into the pane in light mode.
    private func bannerView(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            // Decoration: everything the card says — name, description, author — the pane
            // already reads out as text.
            .accessibilityHidden(true)
    }

    /// Re-resolve the on-disk lookups (font faces, disk usage) when the page's package
    /// changes — and when it becomes installed, the moment there are files to find.
    private var installedTaskID: String { "\(package.id)|\(model.installed[package.id] != nil)" }

    // MARK: - Header

    /// Stacked, not one wide row: a pane is about 300 pt across, and the sheet's icon-name-stats
    /// row beside an action column broke words in half at that width ("openssl@ 3", "Installe d").
    /// Identity, then the action, then the attributes — each with the full width to itself, which
    /// is also the order the App Store's product page uses.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                PackageIconView(package: package, size: 64)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(package.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        kindTag
                        // For casks the title is the display name, so the token is still worth
                        // showing.
                        if package.displayName != nil {
                            Text(package.name)
                                .monospaced()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.subheadline)
                }

                Spacer(minLength: 0)
            }

            // Baselines, not tops: the Installed label beside the bordered Open button hung
            // above it when the row aligned boxes instead of text.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                action
                // Beside the package it opens, not in a dialog footer — there is no dialog. Kept
                // bordered so the one filled button in the pane is always the state-changing one.
                openAction
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Tap-scanned formulae can have no version at all — a bare tag glyph
                // beside nothing read as a broken row, so the row renders only with text.
                if showsVersionRow {
                    statRow("tag") { versionLine }
                }

                // v10 — the App Store's Size row, measured rather than promised: what the
                // installed package occupies, formatted the way Finder would print it.
                // v10.1 — the row is *reserved* from first layout (its presence is knowable
                // synchronously; only the value is slow) and the number fills in place: a
                // row inserting itself mid-list pushed everything below it on every card
                // switch. Redacted text is the system's own skeleton — HIG Loading's "show
                // something as soon as possible", the banner's reservation rule for a row.
                if showsSizeRow {
                    statRow("internaldrive") {
                        if let diskBytes {
                            Text("\(diskBytes.formatted(.byteCount(style: .file))) on disk")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("00.0 MB on disk")
                                .foregroundStyle(.secondary)
                                .redacted(reason: .placeholder)
                                // Scaffolding, not content: VoiceOver hears the row when
                                // it has a number to say.
                                .accessibilityHidden(true)
                        }
                    }
                    .help("The space this package's files take up on disk")
                }

                if let installs = package.installs90d {
                    statRow("chart.bar") {
                        Text("\(installs.formatted(.number)) installs (90 days)")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(installs.formatted(.number)) installs in the last 90 days")
                }

                if let license = package.licenseLabel {
                    statRow("doc.text") {
                        licenseLine(license)
                    }
                }

                // Every package answers "which tap is this from" — core items included, so the
                // row is a constant of the pane, not a third-party oddity. v14 — the value
                // stays a quiet selectable stat (a tinted button shipped first and read as the
                // one loud row in a secondary column); navigation rides a trailing glyph
                // button, the Logs row's composition, wearing chevron.right — the pane's
                // push-tell — not the Logs arrow, which claims another app will open.
                statRow("spigot") {
                    HStack(spacing: 8) {
                        Text(tapLabel)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityLabel("From the \(tapLabel) tap")
                        Button {
                            onPush(.tap(tapLabel))
                        } label: {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Show the packages \(tapLabel) provides")
                        .accessibilityLabel("Show \(tapLabel) packages")
                    }
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var openAction: some View {
        // The model resolves per pass, so an app dragged to the Trash stops being offered.
        let apps = model.launchableApps(for: package)
        if apps.count == 1, let app = apps.first {
            Button("Open") { model.openApp(at: app) }
                .help("Open \(app.deletingPathExtension().lastPathComponent)")
        } else if apps.count > 1 {
            // A handful of casks ship more than one bundle; let the user say which.
            Menu("Open") {
                ForEach(apps, id: \.self) { app in
                    Button(app.deletingPathExtension().lastPathComponent) { model.openApp(at: app) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else if let font = model.installedFontURL(for: package) {
            // Same word, same chrome as an app cask's Open: the payload defines what opening
            // means, and double-clicking a font file in Finder opens Font Book the same way.
            // LaunchServices, no brew, so the safety model is untouched.
            Button("Open") { model.openFile(at: font) }
                .help("Open \(package.title) in Font Book")
        }
    }

    private var fontNames: [String] {
        package.artifacts.first { $0.kind == .font }?.names ?? []
    }

    private var kindTag: some View {
        TagLabel(package.kindLabel, help: package.kindExplanation).font(.caption)
    }

    /// bun's expression is nine licenses long — five wrapped lines that dwarf the header. Past
    /// the threshold the row collapses to the first license plus a disclosure ("and 8 more")
    /// whose popover lists them one per row: summary in place, detail on demand, the anchored
    /// spring for free.
    @ViewBuilder private func licenseLine(_ license: String) -> some View {
        let components = package.licenseComponents
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

    /// Installed and outdated always have a version to show; otherwise only a non-empty
    /// catalog version earns the row.
    private var showsVersionRow: Bool {
        switch model.status(for: package) {
        case .installed, .outdated: true
        case .notInstalled, .busy: !package.version.isEmpty
        }
    }

    @ViewBuilder
    private var versionLine: some View {
        switch model.status(for: package) {
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
            if !package.version.isEmpty {
                Text("Version \(package.version.shortVersion)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var action: some View {
        switch model.status(for: package) {
        case .busy:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working on \(package.title)")
        case .installed:
            Label {
                Text("Installed").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .accessibilityLabel("\(package.title) is installed")
        case .outdated:
            Button("Update") { model.upgrade(package) }
                .buttonStyle(.borderedProminent)
                .disabled(isPinned)
                .help(isPinned
                      ? "\(package.title) is pinned, so Brewery leaves it alone."
                      : "Update \(package.title)")
                .accessibilityLabel("Update \(package.title)")
        case .notInstalled:
            // v10 — no caption under Install: the trust disclosure moved into the consent
            // dialog, which appears only when installing would actually grant new trust.
            // The old always-on "Trusts user/tap" line named the wrong scope (the grant is
            // per-item) and kept showing for taps already trusted, where it disclosed nothing.
            Button("Install") { model.install(package) }
                .buttonStyle(.borderedProminent)
                .disabled(package.disabled)
                .help(installHelp)
                .accessibilityLabel("Install \(package.title)")
        }
    }

    private var installHelp: String {
        if package.disabled {
            return "Homebrew has disabled this package, so it can no longer be installed."
        }
        if model.installNeedsTrustConsent(package), let tap = model.effectiveTap(for: package) {
            return "Install \(package.title) — you'll be asked to trust \(tap) first."
        }
        return "Install \(package.title)"
    }

    private var isPinned: Bool {
        model.outdated[package.id]?.pinned == true
    }

    /// The effective tap (receipt over catalog), falling back to the core tap the kind implies.
    private var tapLabel: String {
        model.effectiveTap(for: package) ?? package.tapLabel
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
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Caveats")

            ForEach(Array(CaveatFormat.blocks(of: text).enumerated()), id: \.offset) { _, block in
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

    /// v13 — a handful of commands reads inline as one copyable word list; past this the run
    /// is a wall (llvm ships 112 — the fonts lesson in prose form), so the section shows the
    /// count and the full list lives one page down the pane's own stack.
    private static let inlineCommandLimit = 8

    /// The executables the formula puts on `PATH`, as one copyable list — a word list, not chips.
    private var commands: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Commands")

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
            sectionTitle("Contents")

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

    // MARK: - Font preview

    private static let fontSample = "The quick brown fox jumps over the lazy dog."
    private static let faceLimit = 6

    /// Each shown face demonstrated in itself — for a font cask the glyphs are the
    /// payload, so this is the screenshots slot. Bounded, never expanding: the pane
    /// samples a font, and the full specimen is Font Book's job (the Open button above).
    /// A Show-More expander shipped first and died in review — 96 inline rows buried
    /// every section below the preview. Faces resolve once per page (the `.task`),
    /// not per pass: CoreText parses the files, which is more than a `fileExists` check.
    private var fontPreview: some View {
        let multiFamily = Set(fontFaces.map(\.family)).count > 1

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Preview")

            ForEach(fontFaces) { face in
                VStack(alignment: .leading, spacing: 1) {
                    Text(faceTitle(face, qualified: multiFamily))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.fontSample)
                        // Relative, so the sample tracks text-size settings like every
                        // built-in style (HIG Typography, custom-font accessibility).
                        .font(.custom(face.postScriptName, size: 18, relativeTo: .title3))
                        .lineLimit(1)
                }
                // The pangram is decoration; rows of it read aloud would bury the one
                // fact each row carries — which face this is.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(faceTitle(face, qualified: true)) sample")
            }

            // No silent cap: what the selection left out is stated, and where to see it.
            if fontFacesDropped > 0 {
                Text(fontFacesDropped == 1
                     ? "And 1 more style in Font Book"
                     : "And \(fontFacesDropped) more styles in Font Book")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The style name, family-qualified when a pack ships several families.
    private func faceTitle(_ face: FontPreview.Face, qualified: Bool) -> String {
        if face.style.isEmpty { return face.family }
        return qualified ? "\(face.family) \(face.style)" : face.style
    }

    /// The formula's background service: the toggle when it is installed, then the definition in
    /// the same two-column grid Contents uses. What it runs, when, where it listens, where it logs.
    private func serviceSection(_ service: ServiceDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Service")

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
            sectionTitle("Conflicts with")

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
            sectionTitle(title)

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
    /// as plain text. Native `AttributedString` for a native `Text` (v9): the base font is the
    /// view's own `.font(.callout)`, which the code spans' run-level font overrides.
    static func attributed(_ paragraph: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: paragraph,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(paragraph)

        // Code spans: the mono face plus a quiet chip, matching the code blocks' language.
        // Ranges are collected first — attribute writes coalesce runs mid-iteration.
        let codeRanges = result.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            result[range].font = .callout.monospaced()
            result[range].backgroundColor = Color(nsColor: .quaternarySystemFill)
        }

        // Bare URLs become real links (where Markdown didn't already make one). The detector
        // speaks NSRange over the plain string; both index spaces count characters, so offsets
        // carry across.
        let plain = String(result.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
                let lower = result.characters.index(
                    result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
                let upper = result.characters.index(
                    result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.upperBound))
                guard !result[lower..<upper].runs.contains(where: { $0.link != nil }) else { continue }
                result[lower..<upper].link = url
            }
        }
        return result
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

/// v13 — the Commands section's summary row when the run would be a wall: the count as the
/// descriptive label, RelatedRow's chrome, the pane's drill-down as the disclosure. A real
/// button for the same reason RelatedRow is one.
private struct CommandsRow: View {
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Text("\(count) commands")

                Spacer(minLength: 8)

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
        .accessibilityLabel("\(count) commands")
        .accessibilityHint("Shows the full command list")
        .help("Show all commands")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }
}

/// v13 — the full command list, one per row: a scannable column where the inline run was a
/// wall. Lazy because texlive ships hundreds; selectable like the run it replaces.
private struct CommandsPage: View {
    let package: Package

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("Commands")
                    .font(.subheadline)
                    .fontWeight(.semibold)

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
                Text(tap)
                    .font(.subheadline)
                    .fontWeight(.semibold)

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
