//
//  CheckupView.swift
//  Brewery
//

import SwiftUI

/// v19 — the Checkup report: `brew doctor`, on demand. Four states — an intro with the one
/// action (doctor is slow and its findings advisory; running it uninvited is the annoying
/// thing this app doesn't do), an indeterminate spinner (HIG *Progress indicators*: unknown
/// duration; doctor deliberately runs its slow checks last), Software Update's positive
/// empty state for a clean bill, and a findings list. Each finding shows brew's own text,
/// its remediation commands as **copyable, never executable** chips — arbitrary command
/// strings stay outside the whitelist by construction — and the packages it names as the
/// pane's own navigation rows, which select into the inspector.
struct CheckupView: View {
    @Environment(AppModel.self) private var model
    let searchText: String

    var body: some View {
        if model.isRunningCheckup {
            running
        } else {
            switch model.checkupOutcome {
            case nil:
                intro
            case .report(let report) where report.findings.isEmpty:
                clean
            case .report(let report):
                findingsList(report)
            case .unreadable(let raw):
                unreadable(raw)
            case .failed:
                failed
            }
        }
    }

    // MARK: - States

    private var intro: some View {
        ContentUnavailableView {
            Label("Check Homebrew's Health", systemImage: "stethoscope")
        } description: {
            Text("Runs Homebrew's own diagnostic checks for common problems — broken symlinks, missing dependencies, permission issues.")
        } actions: {
            runButton("Run Checkup")
                .buttonStyle(.borderedProminent)
        }
    }

    /// The app's one working grammar — the refresh veil's capsule, not a second spinner style.
    private var running: some View {
        WorkingCapsule(text: "Checking…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clean: some View {
        ContentUnavailableView {
            Label {
                Text("Ready to Brew")
            } icon: {
                // Software Update's green-check grammar: the good outcome, celebrated quietly.
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } description: {
            Text("Homebrew found no problems.\(lastRanSuffix)")
        } actions: {
            runButton("Run Again")
        }
    }

    private var failed: some View {
        ContentUnavailableView {
            Label("Checkup Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Homebrew couldn't run its checks.")
        } actions: {
            runButton("Try Again")
        }
    }

    /// The hidden --json flag changed shape — show what brew said rather than swallowing it.
    private func unreadable(_ raw: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header(caption: "Homebrew reported results Brewery couldn't read.")
                if !raw.isEmpty {
                    CodeChip(code: raw)
                }
                CodeChip(code: "brew doctor")
            }
            .padding(16)
        }
    }

    // MARK: - Findings

    private func findingsList(_ report: DoctorReport) -> some View {
        let shown = filtered(report.findings)
        return Group {
            if shown.isEmpty, isSearching {
                ContentUnavailableView.search
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        header(caption: countCaption(report))
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, finding in
                            findingBox(finding)
                        }
                        // brew prints this preamble before its warnings; --json drops it, but
                        // the calibration it carries is the difference between a to-do list
                        // and a report.
                        Text("These checks help with debugging. If everything you use Homebrew for is working fine, you can ignore them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
        }
    }

    /// v21 — the box reads top-down as brew wrote it: the problem, the prose that introduces
    /// any commands, the commands the app can only offer for copying, then everything it can
    /// do natively — Link rows, package rows, the Clean Up / Show in Taps buttons — and links.
    private func findingBox(_ finding: DoctorReport.Finding) -> some View {
        let remedies = (finding.remediation?.commands ?? []).map(Remedy.classify)
        let chips = remedies.compactMap { if case .chip(let command) = $0 { command } else { nil } }
        // A package already shown with a Link button must not repeat as a plain affects row.
        var seen: Set<Package.ID> = []
        let linkRows = remedies.compactMap { remedy -> (name: String, package: Package?)? in
            guard case .link(let formula) = remedy else { return nil }
            let id = Package.packageID(kind: .formula, name: BrewClient.shortName(formula))
            seen.insert(id)
            return (formula, model.package(for: id))
        }
        let packageRows = remedies.flatMap { remedy -> [Package] in
            guard case .packages(let names, let isCask) = remedy else { return [] }
            return names.compactMap { name in
                let candidates = isCask
                    ? [Package.packageID(kind: .cask, name: name)]
                    : [Package.packageID(kind: .formula, name: name),
                       Package.packageID(kind: .cask, name: name)]
                guard let found = candidates.lazy.compactMap(model.package(for:)).first,
                      seen.insert(found.id).inserted else { return nil }
                return found
            }
        }
        let offersCleanup = remedies.contains(.cleanup)
        let offersTaps = remedies.contains { if case .untap = $0 { true } else { false } }
        let affected = model.resolvedAffected(finding.affects ?? []).filter { !seen.contains($0.id) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    // The Attention rule: warnings wear the banner's colour, not the tint.
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(finding.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The prose introduces the commands, so it hides only when every command went
            // native — the action rows then say it themselves. A text-only remediation (the
            // untrusted-taps finding) keeps its prose: the text is all brew offered.
            if !chips.isEmpty || remedies.isEmpty, let remedy = finding.remediation?.text, !remedy.isEmpty {
                Text(remedy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(chips, id: \.self) { command in
                CodeChip(code: command)
            }

            ForEach(linkRows, id: \.name) { row in
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

            ForEach(packageRows) { package in
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

            if offersCleanup || offersTaps {
                HStack(spacing: 8) {
                    if offersCleanup { cleanupButton }
                    if offersTaps {
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
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }

    /// The Link button's three states, read from the queue: idle, busy, done. No dialog —
    /// link is non-destructive and reversible, the service-toggle rule.
    @ViewBuilder private func linkControl(_ name: String) -> some View {
        let operation = model.linkOperation(for: name)
        if let operation, !operation.isFinished || operation.awaitingRefresh {
            ProgressView()
                .controlSize(.small)
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

    @State private var confirmingCleanup = false

    private var cleanupButton: some View {
        Button("Clean Up…") { confirmingCleanup = true }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.cleanupPending)
            .help("Removes files Homebrew no longer needs")
            .confirmationDialog(CleanupDialog.title,
                                isPresented: $confirmingCleanup, titleVisibility: .visible) {
                Button(CleanupDialog.confirm, role: .destructive) { model.cleanUp() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(CleanupDialog.message)
            }
    }

    // MARK: - Pieces

    private func header(caption: String) -> some View {
        HStack(spacing: 12) {
            Text(caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            runButton("Run Again")
        }
        .font(.callout)
    }

    private func runButton(_ title: String) -> some View {
        Button(title) {
            Task { await model.runCheckup() }
        }
        // Doctor reads state a running mutation is mid-change; a checkup of a moving target
        // would report transients as problems.
        .disabled(model.isQueueActive)
        .help(model.isQueueActive
            ? "Waits until the current operation finishes"
            : "Runs Homebrew's diagnostic checks")
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filtered(_ findings: [DoctorReport.Finding]) -> [DoctorReport.Finding] {
        guard isSearching else { return findings }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return findings.filter { finding in
            finding.text.localizedCaseInsensitiveContains(query)
                || (finding.affects ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func countCaption(_ report: DoctorReport) -> String {
        let count = report.findings.count
        var parts = [count == 1 ? "1 finding" : "\(count) findings"]
        if let ranAt = model.checkupRanAt {
            parts.append("Last checkup at \(ranAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private var lastRanSuffix: String {
        guard let ranAt = model.checkupRanAt else { return "" }
        return " Last checkup at \(ranAt.formatted(date: .omitted, time: .shortened))."
    }
}
