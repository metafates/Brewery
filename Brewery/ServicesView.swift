//
//  ServicesView.swift
//  Brewery
//

import SwiftUI

/// The Services section — System Settings › Login Items, not the card grid: services are state
/// rows. Icon + name + the command it runs, a status word only when it says something, and a
/// trailing switch. Rows open the detail sheet like cards do.
struct ServicesView: View {
    let hits: [SearchHit]
    let isSearching: Bool
    /// While any state work runs, an empty section shows the working capsule instead of
    /// claiming "No Services" — a claim is replaced, never contradicted, while recomputed.
    var isChecking = false
    /// The row the inspector is describing — a list that leads to a detail pane has to keep saying
    /// which item the pane is about.
    var selectedID: Package.ID?
    let onSelect: (Package) -> Void
    let onRefresh: () -> Void

    var body: some View {
        if hits.isEmpty {
            emptyState
                .animation(.smooth(duration: 0.3), value: isChecking)
        } else {
            // No header: a section header holding only prose is a paragraph in a label's slot —
            // it truncates, and the window title already says "Services · N services". What the
            // banner was really explaining is a consequence of one control, and it now lives on
            // that control (HIG *Offering help* → macOS: "Explain the action or task the control
            // initiates", "Be brief") — where it is still there the day you flip the switch.
            // Selection is the List's own (the report lists' rule): one highlight
            // grammar app-wide, drawn by the system.
            List(selection: selection) {
                ForEach(hits) { hit in
                    ServiceRow(package: hit.package)
                        .tag(hit.package.id)
                }
            }
            .listStyle(.inset)
        }
    }

    /// Selecting routes through the app's one selection funnel; deselection (⎋) is ignored —
    /// the inspector, not the list, owns "nothing is selected".
    private var selection: Binding<Package.ID?> {
        Binding(get: { selectedID },
                set: { id in
                    guard let id, let hit = hits.first(where: { $0.package.id == id }) else { return }
                    onSelect(hit.package)
                })
    }

    @ViewBuilder private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search
        } else if isChecking {
            WorkingCapsule(text: "Checking for updates…")
        } else {
            ContentUnavailableView {
                Label("No Services", systemImage: "server.rack")
            } description: {
                Text("Installed formulae that provide background services appear here.")
            } actions: {
                Button("Check Again", action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One service: the shared row shape, the switch its own control so a row click selects
/// without ever toggling a daemon by accident.
private struct ServiceRow: View {
    let package: Package

    @Environment(AppModel.self) private var model

    var body: some View {
        StateRow(title: package.title,
                 subtitle: commandLine,
                 subtitleMonospaced: true,
                 subtitleTruncation: .middle) {
            PackageIconView(package: package, size: 32)
        } accessory: {
            // Speaks only when it has something to say — running, scheduled, or failed. The
            // quiet states are what the switch position already shows.
            ServiceStatusLabel(package: package)
                .font(.caption)

            ServiceToggle(package: package)
        }
        .accessibilityHint("Shows package details")
        // The cards' rule (HIG Context menus: support them consistently throughout the app):
        // the switch's action by name, absent — not dimmed — while busy or root-gated.
        .contextMenu {
            if model.status(for: package) != .busy, package.service?.requireRoot != true {
                if model.serviceStatus(for: package)?.health.isLoaded == true {
                    Button("Stop") { model.stopService(package) }
                } else {
                    Button("Start") { model.startService(package) }
                }
            }
            // Present once the service has actually logged; absent, not dimmed.
            if let url = model.serviceLogURL(for: package) {
                Button("Open Log") { model.openFile(at: url) }
            }
            Divider()
            // The shared package base every package row carries.
            PackageMenuItems(package: package)
        }
    }

    /// "redis-server /opt/homebrew/etc/redis.conf" — argv0's basename plus the arguments, with
    /// the real prefix substituted. nil when the scan/synthesis gave us no service block.
    private var commandLine: String? {
        guard let run = package.service?.run, let first = run.first else { return nil }
        let name = first.split(separator: "/").last.map(String.init) ?? first
        let rest = run.dropFirst().map { Package.substitutingPrefix($0, prefix: model.client.prefix) }
        return ([name] + rest).joined(separator: " ")
    }

}

/// The colored-dot status line, shared by the Services rows and the detail sheet so both name a
/// state the same way. `quietLabel` gives the boring states a word where one is needed — the
/// sheet's toggle row must be labeled (a switch anchored to nothing reads as decoration), while
/// list rows stay silent and let the switch position speak.
struct ServiceStatusLabel: View {
    let package: Package
    var quietLabel: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.serviceStatus(for: package)
        switch status?.health {
        case .started:
            caption("Running", color: .green)
        case .scheduled:
            caption("Scheduled", color: .orange)
        case .error:
            caption(status?.exitCode.map { "Failed (exit \($0))" } ?? "Failed", color: .red)
        default:
            if let quietLabel {
                caption(quietLabel, color: .secondary)
            }
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        StatusDotLabel(text: text, color: color)
    }
}

/// The one switch for a service, shared by the row and the detail sheet so both read and write
/// the same truth. Flips enqueue `brew services start`/`stop`; while that operation is queued or
/// running the switch yields to the spinner the rest of the app uses for busy.
struct ServiceToggle: View {
    let package: Package

    @Environment(AppModel.self) private var model

    var body: some View {
        if model.status(for: package) == .busy {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working on \(package.title)")
        } else if package.service?.requireRoot == true {
            // Started as a user, a root service warns, proceeds and fails later — a disabled
            // switch is honest; offering the start would not be.
            Toggle("", isOn: .constant(false))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(true)
                .help("\(package.title) requires root — manage it in Terminal with sudo brew services.")
                // A tooltip is pointer-only, so the same explanation has to reach the
                // accessibility tree — without it VoiceOver reads an unnamed disabled switch.
                .accessibilityLabel("\(package.title) service")
                .accessibilityHint("Requires root — manage it in Terminal with sudo brew services.")
        } else {
            Toggle("", isOn: isLoaded)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                // The tooltip states the consequence, not the control's name — a switch already
                // says "start" by its position, and what a newcomer cannot see is the login part.
                // `brew services stop` "unregister[s] it from launching at login", so the off side
                // is a two-part fact too (brew: services/subcommand/stop.rb).
                .help(consequence)
                // A tooltip is pointer-only; VoiceOver gets the same sentence as the hint, and
                // keeps the package name in the label where it belongs.
                .accessibilityLabel(isLoaded.wrappedValue ? "Stop \(package.title) service"
                                                          : "Start \(package.title) service")
                .accessibilityHint(consequence)
        }
    }

    private var consequence: String {
        isLoaded.wrappedValue ? "Stops now and won't start at login"
                              : "Starts now and at every login"
    }

    private var isLoaded: Binding<Bool> {
        Binding(
            get: { model.serviceStatus(for: package)?.health.isLoaded ?? false },
            set: { load in
                if load {
                    model.startService(package)
                } else {
                    model.stopService(package)
                }
            })
    }
}
