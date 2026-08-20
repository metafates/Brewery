//
//  BreweryApp.swift
//  Brewery
//
//  Created by vzbarashchenko on 09.08.2026.
//

import AppKit
import SwiftUI
import TipKit

@main
struct BreweryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    /// The same keys `ContentView` binds; `@AppStorage` is how a `Commands` builder and
    /// a view share a preference without threading it through the model.
    @AppStorage("installed.sort") private var installedSort: InstalledSort = .name
    @AppStorage("discover.kindFilter") private var kindFilter: KindFilter = .all
    @AppStorage("discover.hideDeprecated") private var hideDeprecated = false
    @AppStorage("discover.tapsOnly") private var tapsOnly = false
    @AppStorage("installed.kindFilter") private var installedKindFilter: KindFilter = .all
    @AppStorage("installed.tapsOnly") private var installedTapsOnly = false
    @AppStorage("installed.showDependencies") private var showDependencies = false

    init() {
        // One-time coaching tips (Discover's kinds explainer); dismissal persists.
        try? Tips.configure()
    }

    /// The section on screen decides which section's keys the Filter commands drive.
    private var currentKindFilter: Binding<KindFilter> {
        model.selection == .installed ? $installedKindFilter : $kindFilter
    }

    private var currentTapsOnly: Binding<Bool> {
        model.selection == .installed ? $installedTapsOnly : $tapsOnly
    }

    var body: some Scene {
        // A single window, not a `WindowGroup`: there is one catalog, one queue and one set of
        // filters, so a second window would be the same app twice — and ⌘N offering one while
        // closing any window quits the app was a promise the scene never kept.
        Window("Brewery", id: "main") {
            ContentView()
                // Wide enough that the sidebar, two columns of cards and the info pane all fit at
                // the minimum: a pane that squeezes the grid to one card is not a pane worth having.
                .frame(minWidth: 1000, minHeight: 600)
                .environment(model)
                .task { await model.bootstrap() }
                .onAppear { appDelegate.model = model }
                // The App Store and Software Update badge the Dock with how many updates wait;
                // the sidebar already says it, and this says it while Brewery is not frontmost.
                .onChange(of: model.outdated.count, initial: true) { _, count in
                    NSApp.dockTile.badgeLabel = count > 0 ? count.formatted(.number) : nil
                }
        }
        // Opens using the display instead of hugging the 900×600 floor: a grid of cards is exactly
        // the content macOS asks you to give more room, not less.
        .defaultSize(width: 1200, height: 780)
        .commands {
            // The sidebar's destinations, at the top of View and above the framework's own Show
            // Sidebar item: the menu bar is where macOS expects every navigation target to be
            // reachable, and ⌘1…⌘5 is the only keyboard path to them.
            CommandGroup(before: .sidebar) {
                // The menu mirrors the sidebar's two groups, divider where the groups break.
                ForEach(SidebarSection.library) { item in
                    // A Toggle in a menu draws the checkmark macOS uses for "you are here".
                    // Switching off is meaningless for a destination, so only `true` acts.
                    Toggle(item.title, isOn: Binding(
                        get: { model.selection == item },
                        set: { if $0 { model.selection = item } }
                    ))
                    .keyboardShortcut(item.shortcut)
                }
                Divider()
                ForEach(SidebarSection.reports) { item in
                    Toggle(item.title, isOn: Binding(
                        get: { model.selection == item },
                        set: { if $0 { model.selection = item } }
                    ))
                    .keyboardShortcut(item.shortcut)
                }
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Divider()
                // Both drill-downs' one keyboard exit; two view-level ⌘[ claims let SwiftUI
                // pick an owner arbitrarily, and a drilled-in pane could lose its back key.
                Button("Back") { model.requestBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.selectedTap == nil && model.paneDepth == 0)
                Divider()
                // The Sort By rule, applied to its Filter twin: every toolbar action needs a
                // menu bar command. One stable item set (the menu bar's same-items rule): one
                // Kind picker bound to the section on screen, each toggle disabled where its
                // section isn't current, the whole menu disabled elsewhere.
                Menu("Filter") {
                    Picker("Kind", selection: currentKindFilter) {
                        ForEach(KindFilter.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Hide Deprecated", isOn: $hideDeprecated)
                        .disabled(model.selection != .discover)
                    Toggle("From Taps Only", isOn: currentTapsOnly)
                    Toggle("Show Dependencies", isOn: $showDependencies)
                        .disabled(model.selection != .installed)
                }
                .disabled(model.selection != .discover && model.selection != .installed)
                // The sort menu's menu-bar twin. Always present, disabled outside
                // Installed ("always show the same set of menu items" — the menu bar's rule),
                // Toggles for the you-are-here checkmark (the destinations' pattern), ⌃⌘1…3 —
                // Finder's own sort-by modifier family.
                Menu("Sort By") {
                    ForEach(InstalledSort.allCases) { sort in
                        Toggle(sort.title, isOn: Binding(
                            get: { installedSort == sort },
                            set: { if $0 { installedSort = sort } }
                        ))
                        .keyboardShortcut(sort.shortcut, modifiers: [.command, .control])
                    }
                }
                .disabled(model.selection != .installed)
                Divider()
                // Show/Hide rather than a checkmark: HIG asks a view's menu item to name the state
                // it will produce.
                Button(model.showInspector ? "Hide Info" : "Show Info") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i")

                Button(model.showOperations ? "Hide Operations" : "Show Operations") {
                    model.showOperations.toggle()
                }
                // ⌥⌘L, Safari's Downloads — the popover this app grew from.
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model.operations.isEmpty)
            }
            // The app's own commands earn their own menu: they act on Homebrew, not on the view.
            CommandMenu("Homebrew") {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(model.isRefreshing)

                Button("Update All") {
                    model.upgradeAll()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.outdated.isEmpty)

                // The context menu's twin (a context item must also exist in the main
                // interface, and the shortcut shows here, not there). ⌘⌫ is the platform's
                // delete family (Finder, App Store); the dynamic title names the target, like
                // Finder's "Eject <disk>". Always present, disabled when nothing uninstallable
                // is selected — HIG The menu bar: the same set of items, always.
                Button(model.uninstallableSelection.map { "Uninstall \($0.title)…" } ?? "Uninstall…") {
                    if let package = model.uninstallableSelection { model.uninstall(package) }
                }
                .keyboardShortcut(.delete)
                .disabled(model.uninstallableSelection == nil)

                // No ellipsis: no dialog follows — pin is non-destructive and mutually
                // inverse (the service-toggle rule); the title names the verb that will run.
                Button(model.pinTargetSelection.map {
                    model.isPinned($0) ? "Unpin \($0.title)" : "Pin \($0.title)"
                } ?? "Pin") {
                    if let package = model.pinTargetSelection { model.togglePin(package) }
                }
                .disabled(model.pinTargetSelection == nil)

                Divider()

                // The whole-Homebrew verbs that lived only on content buttons. Each ellipsis
                // item opens the same confirmation its button does — the dialog runs before
                // the model, everywhere.
                Button("Run Checkup") {
                    model.selection = .checkup
                    Task { await model.runCheckup() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.isQueueActive || model.isRunningCheckup)

                Button("Clean Up…") { model.confirmingCleanup = true }
                    .disabled(model.cleanupPending)

                Button("Remove All Orphans…") { model.confirmingAutoremove = true }
                    .disabled(model.autoremovePending || model.orphanIDs.isEmpty)

                Divider()

                // ⌘. — the platform's cancel key, aimed at the app's one running operation:
                // the popover row and the log window's toolbar act on the same one.
                Button("Cancel Operation") {
                    if let running = model.operations.first(where: { $0.state == .running }) {
                        model.cancel(running)
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.operations.contains { $0.state == .running })

                Divider()

                Button("Add Tap…") { model.requestAddTap() }

                // The Uninstall command's dynamic-title grammar; built-in pages have no
                // TapInfo and stay disabled.
                Button(model.selectedTap.map { "Remove \($0)…" } ?? "Remove Tap…") {
                    if let tap = model.selectedTap,
                       let info = model.tapInfos.first(where: { $0.name == tap }) {
                        model.pendingTapRemoval = info
                    }
                }
                .disabled(!model.tapInfos.contains { $0.name == model.selectedTap })
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // The standard Edit ▸ Find ▸ Find… shape. Wired explicitly rather than left to
                // `.searchable`, whose automatic ⌘F binding has been inconsistent across releases.
                Menu("Find") {
                    Button("Find…") { model.requestFind() }
                        .keyboardShortcut("f")
                }
            }
            // The system's Help menu is a search field over a help book this app does not ship.
            // Two links to the documentation the app is a front end for are worth more.
            CommandGroup(replacing: .help) {
                Link("Homebrew Documentation",
                     destination: URL(string: "https://docs.brew.sh")!)
                Link("Formulae and Casks Explained",
                     destination: URL(string: "https://docs.brew.sh/FAQ")!)
            }
        }

        // One auxiliary window per operation's log (HIG *Windows*: "consider providing the
        // option to view content in a new window"), opened from the operations popover and
        // listed in the Window menu by its operation title. The scene contributes File ▸
        // New Log Window (even without a default value) — accepted: it opens the designed
        // No Operation state, and every way of suppressing it (.commandsRemoved(), an empty
        // .newItem group) takes the whole File menu — Close ⌘W included — down with it.
        // The single-window rule still holds: the *main* window has no New command.
        // Restoration is off: operations are session state, and a restored log of a dead
        // queue would be an empty shell.
        WindowGroup("Log", id: "operation-log", for: BrewOperation.ID.self) { $operationID in
            OperationLogWindow(operationID: operationID)
                .environment(model)
        }
        .defaultSize(width: 580, height: 440)
        .restorationBehavior(.disabled)
    }
}

/// Quitting mid-install would leave a half-written keg behind, so the terminate path asks first
/// and then gives brew the same SIGINT that Cancel sends.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnfinishedMutations else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A Homebrew operation is still in progress."
        alert.informativeText = "Quitting now stops it, which can leave a partial installation behind."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Running")
        // Return stays on Quit (Safari/Terminal's order), but the destructive choice says so,
        // and Escape means the safe one — it meant nothing.
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        model.interruptRunning()
        Task {
            // brew traps Interrupt and exits promptly; if it somehow does not, an orphaned child
            // is the lesser evil versus a quit that never completes.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while model.isMutating, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Short and focused, per the Dock menu guidance: the two things worth asking of a package
    /// manager without bringing its window forward.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        menu.addItem(item(title: "Refresh", action: #selector(refreshFromDock)))
        let outdated = model.outdated.count
        if outdated > 0 {
            menu.addItem(item(title: "Update All (\(outdated))", action: #selector(updateAllFromDock)))
        }
        return menu
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshFromDock() {
        Task { await model?.refresh() }
    }

    @objc private func updateAllFromDock() {
        model?.upgradeAll()
    }
}
