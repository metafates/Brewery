//
//  BrewCommandTests.swift
//  BreweryTests
//

import Foundation
import Testing

@testable import Brewery

@Suite("BrewCommand")
struct BrewCommandTests {

    // MARK: - Exact argv

    @Test("read commands")
    func readArguments() {
        #expect(BrewCommand.listFormulae.arguments == ["list", "--versions"])
        #expect(BrewCommand.listCasks.arguments == ["list", "--cask", "--versions"])
        #expect(BrewCommand.outdated.arguments == ["outdated", "--json=v2"])
    }

    @Test("mutating commands")
    func mutatingArguments() {
        #expect(BrewCommand.update.arguments == ["update"])
        #expect(BrewCommand.upgradeAll.arguments == ["upgrade"])
        #expect(BrewCommand.install(name: "wget", cask: false).arguments == ["install", "--formula", "wget"])
        #expect(BrewCommand.install(name: "iterm2", cask: true).arguments == ["install", "--cask", "iterm2"])
        #expect(BrewCommand.upgrade(name: "wget", cask: false).arguments == ["upgrade", "--formula", "wget"])
        #expect(BrewCommand.upgrade(name: "iterm2", cask: true).arguments == ["upgrade", "--cask", "iterm2"])
    }

    @Test("only update/install/upgrade mutate")
    func isMutating() {
        #expect(BrewCommand.listFormulae.isMutating == false)
        #expect(BrewCommand.listCasks.isMutating == false)
        #expect(BrewCommand.outdated.isMutating == false)
        #expect(BrewCommand.update.isMutating)
        #expect(BrewCommand.upgradeAll.isMutating)
        #expect(BrewCommand.install(name: "wget", cask: false).isMutating)
        #expect(BrewCommand.upgrade(name: "wget", cask: false).isMutating)
    }

    @Test("the package name is a single argv element")
    func nameIsOneArgument() {
        // No /bin/sh -c anywhere, so a name is passed through verbatim rather than re-parsed.
        let hostile = "wget; rm -rf /"
        #expect(BrewCommand.install(name: hostile, cask: false).arguments == ["install", "--formula", hostile])
    }

    // MARK: - Destructive-token tripwire

    /// Every representable command. Kept exhaustive by `commandKind` below.
    static var everyCommand: [BrewCommand] { [
        .listFormulae,
        .listCasks,
        .outdated,
        .update,
        .install(name: "wget", cask: false),
        .install(name: "iterm2", cask: true),
        .upgrade(name: "wget", cask: false),
        .upgrade(name: "iterm2", cask: true),
        .upgradeAll,
    ] }

    /// One tag per `BrewCommand` case. The switch is exhaustive on purpose: adding a case to
    /// `BrewCommand` stops this file compiling until the case is tagged *and* added to
    /// `everyCommand`, so the tripwire below can never silently miss a new command.
    enum CommandKind: CaseIterable {
        case listFormulae, listCasks, outdated, update, install, upgrade, upgradeAll
    }

    static func commandKind(_ command: BrewCommand) -> CommandKind {
        switch command {
        case .listFormulae: .listFormulae
        case .listCasks: .listCasks
        case .outdated: .outdated
        case .update: .update
        case .install: .install
        case .upgrade: .upgrade
        case .upgradeAll: .upgradeAll
        }
    }

    @Test("the tripwire covers every case of the enum")
    func everyCommandIsCovered() {
        #expect(Set(Self.everyCommand.map(Self.commandKind)) == Set(CommandKind.allCases))
    }

    @Test("first argv token is on the whitelist")
    func firstTokenIsWhitelisted() {
        let allowed: Set<String> = ["list", "outdated", "update", "install", "upgrade"]
        for command in Self.everyCommand {
            let first = command.arguments.first ?? ""
            #expect(allowed.contains(first), "unexpected subcommand \"\(first)\" in \(command.arguments)")
        }
    }

    @Test("no argv element carries a destructive token")
    func noDestructiveTokens() {
        let forbidden = ["uninstall", "remove", "rm", "cleanup", "pin", "unpin", "zap", "--force"]
        for command in Self.everyCommand {
            for argument in command.arguments {
                // Whole tokens and their flag variants ("--force-bottle"); a plain substring test
                // would flag the innocent "rm" inside "--formula".
                let lowered = argument.lowercased()
                let hit = forbidden.first { lowered == $0 || lowered.hasPrefix("\($0)-") || lowered.hasPrefix("\($0)=") }
                #expect(hit == nil, "\(command.arguments) carries destructive token \"\(hit ?? "")\"")
            }
        }
    }

    @Test("install/upgrade of one package carry the explicit kind token")
    func explicitKindToken() {
        for command in Self.everyCommand {
            let arguments = command.arguments
            switch Self.commandKind(command) {
            case .install, .upgrade:
                #expect(arguments.count == 3, "\(arguments)")
                #expect(arguments.dropFirst().first == "--formula" || arguments.dropFirst().first == "--cask",
                        "\(arguments) has no explicit kind token")
            case .upgradeAll:
                // Bare `brew upgrade` — no name, so there is nothing to disambiguate.
                #expect(arguments == ["upgrade"])
            case .listFormulae, .listCasks, .outdated, .update:
                #expect(!arguments.contains("--formula"))
            }
        }
    }
}
