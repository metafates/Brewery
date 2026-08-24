//
//  CheckupView.swift
//  Brewery
//

import SwiftUI

/// The Checkup report: `brew doctor`, on demand. Four states — an intro with the one
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
        Group {
            if model.isRunningCheckup, !model.checkupHasContent {
                // A claim state has nothing that stays valid while doctor runs — the wait
                // replaces the claim (Software Update's grammar).
                WorkingCapsule(text: "Checking…")
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
        // Previous findings stay on screen while doctor re-runs — still-valid data the work
        // never takes; the header caption narrates the run instead.
        .animation(.smooth(duration: 0.3), value: model.isRunningCheckup)
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
            // The sole action in an unavailable state is prominent, app-wide.
            runButton("Run Again")
                .buttonStyle(.borderedProminent)
        }
    }

    private var failed: some View {
        ContentUnavailableView {
            Label("Checkup Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Homebrew couldn't run its checks.")
        } actions: {
            runButton("Try Again")
                .buttonStyle(.borderedProminent)
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
                        ForEach(shown) { finding in
                            FindingBox(finding: finding)
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

    // MARK: - Pieces

    private func header(caption: String) -> some View {
        HStack(spacing: 12) {
            if model.isRunningCheckup {
                // The freshness caption's grammar: the previous findings stay on screen —
                // still-valid data — while the header names the work replacing them.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                }
                .accessibilityElement(children: .combine)
                .foregroundStyle(.secondary)
            } else {
                Text(caption)
                    .foregroundStyle(.secondary)
            }
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
        // would report transients as problems. Disabled while one runs, too: the model
        // guard already no-ops a re-click, and an enabled button that does nothing lies.
        .disabled(model.isQueueActive || model.isRunningCheckup)
        .help(model.isRunningCheckup
            ? "A checkup is already running"
            : model.isQueueActive
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
