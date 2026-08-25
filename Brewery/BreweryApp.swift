//
//  BreweryApp.swift
//  Brewery
//
//  Created by metafates on 09.08.2026.
//

import AppKit
import SwiftUI
import TipKit

@main
struct BreweryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The delegate owns the model: bootstrap, the quit guard and the Dock menu must all
    /// work with zero windows (silent login launch, the background check), and the delegate
    /// is the one object guaranteed to exist for the process's whole life.
    private var model: AppModel { appDelegate.model }
    /// The same keys `ContentView` binds; `@AppStorage` is how a `Commands` builder and
    /// a view share a preference without threading it through the model.
    @AppStorage("installed.sort") private var installedSort: InstalledSort = .name
    @AppStorage("discover.kindFilter") private var kindFilter: KindFilter = .all
    @AppStorage("discover.hideDeprecated") private var hideDeprecated = false
    @AppStorage("discover.tapsOnly") private var tapsOnly = false
    @AppStorage("installed.kindFilter") private var installedKindFilter: KindFilter = .all
    @AppStorage("installed.tapsOnly") private var installedTapsOnly = false
    @AppStorage("installed.showDependencies") private var showDependencies = false
    @AppStorage("installed.pinnedOnly") private var installedPinnedOnly = false
    /// The extra's presence is the user's call (HIG: "Let people — not your app — decide"):
    /// this key backs both `isInserted` and the View-menu twin.
    @AppStorage("menubar.shown") private var menuBarShown = true

    init() {
        // One-time coaching tips (Discover's kinds explainer); dismissal persists.
        try? Tips.configure()
    }

    /// `isInserted` must NOT bind `$menuBarShown` directly: the scene writes the current
    /// value back on every update, and a same-value `@AppStorage` write invalidates the
    /// scene again — a permanent per-frame re-render loop pegging the main thread (found
    /// via `sample`: `NSRunLoop.flushObservers` at 100%). The guard breaks the cycle;
    /// real changes (the Hide items, dragging the icon off the bar) still propagate.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { menuBarShown },
            set: { if $0 != menuBarShown { menuBarShown = $0 } }
        )
    }

    /// The section on screen decides which section's keys the Filter commands drive. A drilled
    /// tap page has one too — transient and model-side, which is what lets a `Commands` builder
    /// reach it at all; before that, its toolbar Filter was the one action in the app with no
    /// menu bar twin.
    private var currentKindFilter: Binding<KindFilter> {
        switch model.selection {
        case .installed: $installedKindFilter
        case .taps where model.selectedTap != nil: Bindable(model).tapKindFilter
        default: $kindFilter
        }
    }

    private var currentTapsOnly: Binding<Bool> {
        model.selection == .installed ? $installedTapsOnly : $tapsOnly
    }

    /// Where the Filter menu has something to drive: Discover, Installed, and a drilled-in tap
    /// page (the tap *list* filters nothing — it lists taps).
    private var filterApplies: Bool {
        model.selection == .discover || model.selection == .installed
            || (model.selection == .taps && model.selectedTap != nil)
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
        }
        // Opens using the display instead of hugging the 900×600 floor: a grid of cards is exactly
        // the content macOS asks you to give more room, not less.
        .defaultSize(width: 1200, height: 780)
        .commands {
            // The sidebar's destinations, at the top of View and above the framework's own Show
            // Sidebar item: the menu bar is where macOS expects every navigation target to be
            // reachable, and ⌘1…⌘7 is the only keyboard path to them.
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
                    // Explicitly gated now that a tap page can open this menu: unguarded, it
                    // would write Discover's key from a page that never reads it.
                    Toggle("From Taps Only", isOn: currentTapsOnly)
                        .disabled(model.selection != .discover && model.selection != .installed)
                    Toggle("Pinned Only", isOn: $installedPinnedOnly)
                        .disabled(model.selection != .installed)
                    Toggle("Show Dependencies", isOn: $showDependencies)
                        .disabled(model.selection != .installed)
                }
                .disabled(!filterApplies)
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

                // The extra's own Hide item's twin: re-enabling must never need the icon
                // that's gone.
                Button(menuBarShown ? "Hide Menu Bar Icon" : "Show Menu Bar Icon") {
                    menuBarShown.toggle()
                }
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
                .disabled(model.outdated.isEmpty || model.upgradeAllPending)

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
                .disabled(model.isQueueActive || model.isRunningCheckup || model.brewMissing)

                // Disabled with brew missing, like Add Tap… below: `ContentView` renders
                // `brewNotFound` then, so `splitView` — where every confirmation dialog and
                // the add-tap popover live — is not in the tree. The click would set the
                // pending flag with nothing to consume it, and the *next* successful Check
                // Again would mount the split view with the flag already true, presenting a
                // destructive dialog nobody asked for. Refresh stays enabled: it is the
                // re-probe. HIG *Menus*: show people when a menu item is unavailable.
                Button("Clean Up…") { model.confirmingCleanup = true }
                    .disabled(model.cleanupPending || model.brewMissing)

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
                    .disabled(model.brewMissing)

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
            // File ▸ Export Brewfile…, where a save belongs. The File menu exists already
            // (the log scene contributes it); this is the first item the app puts there.
            // The ellipsis is honest: a save panel appears before anything is written.
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Brewfile…") {
                    Task { await model.exportBrewfile() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                // Checkup's rule: a dump mid-mutation describes a moving target.
                .disabled(model.brewMissing || model.isQueueActive || model.isExportingBrewfile)
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

        menuBarExtra
    }

    // The stays-running decision's other half: with the window closed the app still
    // answers for updates, and the menu bar is where that knowledge lives. Default
    // `.menu` style — HIG: "Display a menu — not a popover". Its own property: the
    // scene body sits at the type-checker's expression cliff.
    private var menuBarExtra: some Scene {
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarMenu()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
    }
}

/// Quitting mid-install would leave a half-written keg behind, so the terminate path asks first
/// and then gives brew the same SIGINT that Cancel sends.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bootstrap is the app's, not the window's: a login launch may never open one.
        Task { await model.bootstrap() }

        // Launched at login, the app is menu bar presence only — no window in the face
        // of someone who just logged in. Detection reads the launch open-event in place:
        // a login-item launch carries `keyAELaunchedAsLogInItem` in its property data.
        // (Never `setEventHandler` for `kAEOpenApplication` — that replaces AppKit's own
        // open handling and no launch shows a window at all.) SwiftUI's presentation
        // order against this callback is not documented, so the close runs now and again
        // on the next runloop turn; the app stays running either way.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == UInt32(keyAELaunchedAsLogInItem)
        if launchedAsLoginItem {
            closeMainWindows()
            DispatchQueue.main.async { self.closeMainWindows() }
        }
    }

    /// SwiftUI's `Window("main")` windows carry a "main-AppWindow-N" identifier.
    private func closeMainWindows() {
        for window in NSApp.windows
        where window.identifier?.rawValue.hasPrefix("main") == true {
            window.close()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnfinishedMutations else { return .terminateNow }

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
        let menu = NSMenu()
        menu.addItem(item(title: "Refresh", action: #selector(refreshFromDock)))
        let outdated = model.outdated.count
        // Absent while one is already running: a Dock menu is rebuilt on every open, so it
        // has no disabled state to wear, and an item that silently no-ops is the lie the
        // model guard exists to prevent.
        if outdated > 0, !model.upgradeAllPending {
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
        Task { await model.refresh() }
    }

    @objc private func updateAllFromDock() {
        model.upgradeAll()
    }
}
