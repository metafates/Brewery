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
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(model)
                .task { await model.bootstrap() }
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")

                Button("Upgrade All") {
                    model.upgradeAll()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.outdated.isEmpty)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // Wired explicitly: the automatic ⌘F binding for `.searchable` has been
                // inconsistent across macOS releases.
                Button("Find") {
                    model.requestFind()
                }
                .keyboardShortcut("f")
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
}
