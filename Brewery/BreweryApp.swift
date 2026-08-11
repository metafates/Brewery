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

    init() {
        // One-time coaching tips (Discover's kinds explainer); dismissal persists.
        try? Tips.configure()
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
                ForEach(SidebarSection.allCases) { item in
                    // A Toggle in a menu draws the checkmark macOS uses for "you are here".
                    // Switching off is meaningless for a destination, so only `true` acts.
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
                // Show/Hide rather than a checkmark: HIG asks a view's menu item to name the state
                // it will produce.
                Button(model.showInspector ? "Hide Info" : "Show Info") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i")

                Button(model.showOperations ? "Hide Operations" : "Show Operations") {
                    model.showOperations.toggle()
                }
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

                Divider()

                Button("Add Tap…") { model.requestAddTap() }
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
    }
}

/// Quitting mid-install would leave a half-written keg behind, so the terminate path asks first
/// and then gives brew the same SIGINT that Cancel sends.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isMutating else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A Homebrew operation is still running."
        alert.informativeText = "Quitting now stops it, which can leave a partial installation behind."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Running")
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
