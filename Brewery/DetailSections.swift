//
//  DetailSections.swift
//  Brewery
//

import AppKit
import SwiftUI

// The pane's state-owning sections. Each owns the `@State` and the `.task` it needs, so a
// disk-size landing or a license popover invalidates its own subtree
// instead of re-evaluating the whole page.

/// Stacked, not one wide row: a pane is about 300 pt across, and the sheet's icon-name-stats
/// row beside an action column broke words in half at that width ("openssl@ 3", "Installe d").
/// Identity, then the action, then the attributes — each with the full width to itself, which
/// is also the order the App Store's product page uses.
struct DetailHeader: View {
    let package: Package
    let onPush: (PackageDetailView.Page) -> Void

    @Environment(AppModel.self) private var model
    @State private var showLicenses = false
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

    /// Re-measure when the page's package changes — and when it becomes installed, the moment
    /// there are files to find.
    private var installedTaskID: String { "\(package.id)|\(model.installed[package.id] != nil)" }

    var body: some View {
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
                // Secondary actions behind a quiet ellipsis at the trailing edge
                // (HIG Pull-down buttons: "a More pull-down button presents items that
                // don't need prominent positions"). A bordered Uninstall… shipped first
                // and read as Open's peer — two equal buttons where one destroys is a
                // hierarchy lie; the App Store product page keeps delete off the row for
                // the same reason. The menu mirrors the card's context menu.
                moreMenu
            }

            VStack(alignment: .leading, spacing: 6) {
                // Tap-scanned formulae can have no version at all — a bare tag glyph
                // beside nothing read as a broken row, so the row renders only with text.
                if showsVersionRow {
                    statRow("tag") { versionLine }
                }

                // The App Store's Size row, measured rather than promised: what the
                // installed package occupies, formatted the way Finder would print it.
                // The row is *reserved* from first layout (its presence is knowable
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
                // row is a constant of the pane, not a third-party oddity. The value
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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // A sample is only a summary if it fits one line. An OR-group is one
                // component and long by construction (zstd's "BSD-3-Clause OR
                // GPL-2.0-only" wrapped, floating the button mid-air) — past the budget
                // the row collapses to the Contents section's count grammar instead.
                if first.count <= 24 {
                    Text("License: \(first)")
                        .foregroundStyle(.secondary)
                    licenseDisclosure("and \(components.count - 1) more", components: components)
                } else {
                    licenseDisclosure("\(components.count) licenses", components: components)
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

    /// The license popover's quiet trigger — secondary like the rest of the column, chevron.down
    /// as the pull-down tell (discloses below, where the tap row's chevron.right navigates deeper).
    private func licenseDisclosure(_ title: String, components: [String]) -> some View {
        Button {
            showLicenses = true
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show all licenses")
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

    /// One header stat. `Label` keeps the glyph on the value's first baseline (an `HStack`
    /// centered it against a wrapping license or tap name, floating it mid-block); the
    /// fixed-width icon column still lines the values up — `chart.bar` and `doc.text` are
    /// not the same width.
    private func statRow(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        Label {
            content()
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
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
            // A pin on a current package finally says so — it is also why Uninstall is
            // missing from the menus.
            HStack(spacing: 6) {
                Text("Version \(version.shortVersion) installed")
                    .foregroundStyle(.secondary)
                if isPinned {
                    Text("pinned")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .notInstalled, .busy:
            if !package.version.isEmpty {
                Text("Version \(package.version.shortVersion)")
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                      ? AppModel.pinnedUpdateHelp(package.title)
                      : "Update \(package.title)")
                .accessibilityLabel("Update \(package.title)")
        case .notInstalled:
            // No caption under Install: the trust disclosure moved into the consent
            // dialog, which appears only when installing would actually grant new trust.
            // The old always-on "Trusts user/tap" line named the wrong scope (the grant is
            // per-item) and kept showing for taps already trusted, where it disclosed nothing.
            // The ellipsis appears exactly when the consent dialog will (the dialog-promise
            // rule); the tooltip already said so, now the label agrees.
            Button(model.installNeedsTrustConsent(package) ? "Install…" : "Install") {
                model.install(package)
            }
                .buttonStyle(.borderedProminent)
                .disabled(package.disabled)
                .help(installHelp)
                .accessibilityLabel("Install \(package.title)")
        }
    }

    /// The card context menu's twin in the pane's main interface: Copy Name for every
    /// package, Uninstall… while it is on disk and not pinned or mid-operation — destructive
    /// last, behind a separator (the Delete-last grammar); absent, not dimmed. The dialog the
    /// item opens is the confirm-intent step HIG Pull-down buttons asks for.
    private var moreMenu: some View {
        Menu {
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.name, forType: .string)
            }
            switch model.status(for: package) {
            case .installed, .outdated:
                Button(isPinned ? "Unpin" : "Pin") { model.togglePin(package) }
                if !isPinned {
                    Divider()
                    Button("Uninstall…", role: .destructive) { model.uninstall(package) }
                }
            case .busy, .notInstalled:
                EmptyView()
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(package.title)")
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

    // One rule, hoisted: the card's context menu and the menu bar read the same state.
    private var isPinned: Bool { model.isPinned(package) }

    /// The effective tap (receipt over catalog), falling back to the core tap the kind implies.
    private var tapLabel: String {
        model.effectiveTap(for: package) ?? package.tapLabel
    }
}

/// Each shown face demonstrated in itself — for a font cask the glyphs are the
/// payload, so this is the screenshots slot. Bounded, never expanding: the pane
/// samples a font, and the full specimen is Font Book's job (the Open button above).
/// A Show-More expander shipped first and died in review — 96 inline rows buried
/// every section below the preview. Faces resolve once per page (the `.task`),
/// not per pass: CoreText parses the files, which is more than a `fileExists` check.
struct DetailFontPreview: View {
    let package: Package

    @Environment(AppModel.self) private var model
    @State private var faces: [FontPreview.Face] = []
    @State private var dropped = 0

    private static let sample = "The quick brown fox jumps over the lazy dog."
    private static let faceLimit = 6

    private var fontNames: [String] {
        package.artifacts.first { $0.kind == .font }?.names ?? []
    }

    /// Re-resolve when the page's package changes — and when it becomes installed, the
    /// moment there are files to find.
    private var installedTaskID: String { "\(package.id)|\(model.installed[package.id] != nil)" }

    var body: some View {
        Group {
            if !faces.isEmpty {
                Divider()
                preview
            }
        }
        .task(id: installedTaskID) {
            (faces, dropped) = ([], 0)
            guard package.isFont, model.installed[package.id] != nil else { return }
            (faces, dropped) = await FontPreview.resolve(names: fontNames, limit: Self.faceLimit)
        }
    }

    private var preview: some View {
        let multiFamily = Set(faces.map(\.family)).count > 1

        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Preview")

            ForEach(faces) { face in
                VStack(alignment: .leading, spacing: 1) {
                    Text(faceTitle(face, qualified: multiFamily))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.sample)
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
            if dropped > 0 {
                Text(dropped == 1
                     ? "And 1 more style in Font Book"
                     : "And \(dropped) more styles in Font Book")
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
}
