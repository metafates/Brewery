//
//  MenuBarMenu.swift
//  Brewery
//

import AppKit
import ServiceManagement
import SwiftUI

/// The menu bar extra's status-item label: the mug, plus the outdated count as text while
/// updates wait — the Dock badge's sibling, Battery's percentage precedent (a recorded
/// deviation; the HIG's extra guidance is silent on adorning the symbol). Animation-free
/// on purpose: no Reduce Motion branch is owed.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.outdated.count
        Group {
            if model.isQueueActive {
                // The queue's tell, in the count's slot: a static state glyph, the menu
                // bar's own grammar for "working" (Time Machine, the Finder sync arrows —
                // system extras never animate continuously, and a rasterized label
                // animates unreliably anyway). Static, so no Reduce Motion branch owed.
                //
                // "↻" and not `Image(systemName: "arrow.triangle.2.circlepath")`: a status
                // item's label renders exactly ONE Image and ONE Text — a second Image, or an
                // SF Symbol smuggled in as `Text(Image(systemName:))`, is dropped silently and
                // leaves the bare mug (measured: 34 pt wide, icon only, against 51 pt with this
                // text). U+21BB resolves inside .SFNS-Regular, so it is the system font's own
                // glyph at the count's weight rather than a foreign icon font — unlike U+27F3,
                // which falls back to AppleSymbols.
                Label("↻", systemImage: "mug")
                    .labelStyle(.titleAndIcon)
            } else if count > 0 {
                Label(count.formatted(.number), systemImage: "mug")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "mug")
            }
        }
        // A bare composed label degrades in the AX tree (the toolbar Operations button's
        // lesson) — one element, saying what the adornment means.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labelDescription(count: count))
    }

    private func labelDescription(count: Int) -> String {
        if model.isQueueActive {
            let active = model.activeCount
            return active == 1 ? "Brewery, 1 operation running"
                               : "Brewery, \(active) operations running"
        }
        return count > 0 ? "Brewery, \(count) updates available" : "Brewery"
    }
}

/// The extra's menu (`.menu` style — HIG: "Display a menu — not a popover"). Every item
/// mirrors a command that exists elsewhere; nothing here is extra-only. The status rows are
/// plain `Text` — a menu cannot host a spinner, and a disabled text row is the menu's native
/// grammar for state (recorded deviation). Content rebuilds when the menu opens, so the
/// caption is computed here, timer-free — menus are exactly where periodic scheduling
/// proved unreliable.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menubar.shown") private var menuBarShown = true

    /// Pinned packages are excluded from the rows the same way the card hides its Update
    /// button: `brew upgrade <pinned>` refuses, and a row that fails on click is a lie.
    private var updatable: [Package] {
        model.outdatedPackages.filter { !model.isPinned($0) }
    }

    var body: some View {
        statusRows

        Divider()

        // Dynamic rows are the extras' convention (Wi-Fi's network list) — a recorded
        // deviation from the main menu bar's same-items rule; the tail below stays fixed.
        // Upgrades never need the trust-consent dialog (install is the only consent gate,
        // `installNeedsTrustConsent`), so no row here can ever require the main window.
        ForEach(updatable.prefix(5)) { package in
            Button("\(package.title)  \(versionRun(for: package))") {
                model.upgrade(package)
            }
        }
        if updatable.count > 5 {
            Button("\(updatable.count - 5) More Updates…") { openMain(on: .outdated) }
        }

        // ⇧⌘U for recognition; the binding lives in the Homebrew menu's own item.
        Button("Update All") { model.upgradeAll() }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.outdated.isEmpty || model.upgradeAllPending)

        Divider()

        Button("Open Brewery") { openMain(on: nil) }

        // The ⌘R path under Software Update's verb: explicit requests are never coalesced.
        Button("Check for Updates") { Task { await model.refresh() } }
            .disabled(model.isRefreshing)

        Divider()

        // The app's first behavior preference, living where the behavior is visible.
        // `SMAppService.status` is not observable and opening an extra's menu does not
        // activate the app, so the checked state is read fresh here on every open — the
        // only surface that shows it, so no other resync exists or is needed.
        Toggle("Launch at Login", isOn: launchAtLogin)

        // Re-enabling lives in View ▸ Show Menu Bar Icon — never behind the icon that's gone.
        Button("Hide Menu Bar Icon") { menuBarShown = false }

        Button("Quit Brewery") {
            // Activate first: the quit-guard alert would otherwise appear behind other apps.
            NSApp.activate()
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder private var statusRows: some View {
        if model.isQueueActive {
            let count = model.activeCount
            Text(count == 1 ? "1 operation running" : "\(count) operations running")
        } else {
            let outdated = model.outdated.count
            if outdated > 0 {
                Text(outdated == 1 ? "1 update available" : "\(outdated) updates available")
            } else {
                Text("Everything is up to date")
            }
            if let checked = model.metadataCheckedAt {
                Text(ContentView.lastCheckedCaption(checked: checked, now: .now))
            }
        }
    }

    /// The card's status grammar: "installed → current".
    private func versionRun(for package: Package) -> String {
        guard let info = model.outdated[package.id] else { return "" }
        return "\(info.installed.last?.shortVersion ?? "") → \(info.current.shortVersion)"
    }

    /// Registration happens strictly on this explicit toggle — macOS shows a system
    /// notification on register, so never speculatively — and is only meaningful from an
    /// installed /Applications build (DerivedData registrations go stale). A denial or
    /// `.requiresApproval` routes to System Settings, where the decision actually lives.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    SMAppService.openSystemSettingsLoginItems()
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        )
    }

    /// A status-item click does not make the app frontmost — activate, then open.
    private func openMain(on section: SidebarSection?) {
        NSApp.activate()
        openWindow(id: "main")
        if let section { model.selection = section }
    }
}
