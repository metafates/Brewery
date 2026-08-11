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
        // Bare `brew list --versions` lists casks as well, so the kind token is load-bearing.
        #expect(BrewCommand.listFormulae.arguments == ["list", "--formula", "--versions"])
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

    @Test("service commands: canonical verbs, one named target, no flags")
    func serviceArguments() {
        #expect(BrewCommand.servicesList.arguments == ["services", "list", "--json"])
        #expect(BrewCommand.serviceStart(name: "redis").arguments == ["services", "start", "redis"])
        #expect(BrewCommand.serviceStop(name: "redis").arguments == ["services", "stop", "redis"])
        #expect(BrewCommand.servicesList.isMutating == false)
        #expect(BrewCommand.serviceStart(name: "redis").isMutating)
        #expect(BrewCommand.serviceStop(name: "redis").isMutating)
        // Toggles change launchd state, not packages — no session brew update for them.
        #expect(BrewCommand.serviceStart(name: "redis").touchesPackages == false)
        #expect(BrewCommand.install(name: "wget", cask: false).touchesPackages)
    }

    @Test("tap commands: bare verbs, one name, no flags")
    func tapArguments() {
        #expect(BrewCommand.tap(name: "oven-sh/bun").arguments == ["tap", "oven-sh/bun"])
        #expect(BrewCommand.untap(name: "oven-sh/bun").arguments == ["untap", "oven-sh/bun"])
        #expect(BrewCommand.tap(name: "oven-sh/bun").isMutating)
        #expect(BrewCommand.untap(name: "oven-sh/bun").isMutating)
        // A fresh clone needs no brew update first.
        #expect(BrewCommand.tap(name: "oven-sh/bun").touchesPackages == false)
        #expect(BrewCommand.untap(name: "oven-sh/bun").touchesPackages == false)
    }

    @Test("trust: whole-tap only, explicit type flag, mutating")
    func trustArguments() {
        let trust = BrewCommand.trustTap(name: "charmbracelet/tap")
        #expect(trust.arguments == ["trust", "--tap", "charmbracelet/tap"])
        #expect(trust.isMutating)
        #expect(trust.touchesPackages == false)
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

    @Test("a tap-qualified name is still one argv element, still exactly three tokens")
    func qualifiedName() {
        let install = BrewCommand.install(name: "charmbracelet/tap/gum", cask: false)
        #expect(install.arguments == ["install", "--formula", "charmbracelet/tap/gum"])

        let upgrade = BrewCommand.upgrade(name: "oven-sh/bun/bun", cask: false)
        #expect(upgrade.arguments == ["upgrade", "--formula", "oven-sh/bun/bun"])
        #expect(upgrade.arguments.count == 3)
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
        .servicesList,
        .serviceStart(name: "redis"),
        .serviceStop(name: "redis"),
        .tap(name: "oven-sh/bun"),
        .untap(name: "oven-sh/bun"),
        .trustTap(name: "charmbracelet/tap"),
    ] }

    /// One tag per `BrewCommand` case. The switch is exhaustive on purpose: adding a case to
    /// `BrewCommand` stops this file compiling until the case is tagged *and* added to
    /// `everyCommand`, so the tripwire below can never silently miss a new command.
    enum CommandKind: CaseIterable {
        case listFormulae, listCasks, outdated, update, install, upgrade, upgradeAll
        case servicesList, serviceStart, serviceStop, tap, untap, trustTap
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
        case .servicesList: .servicesList
        case .serviceStart: .serviceStart
        case .serviceStop: .serviceStop
        case .tap: .tap
        case .untap: .untap
        case .trustTap: .trustTap
        }
    }

    @Test("the tripwire covers every case of the enum")
    func everyCommandIsCovered() {
        #expect(Set(Self.everyCommand.map(Self.commandKind)) == Set(CommandKind.allCases))
    }

    @Test("first argv token is on the whitelist")
    func firstTokenIsWhitelisted() {
        let allowed: Set<String> = ["list", "outdated", "update", "install", "upgrade", "services", "tap", "untap", "trust"]
        for command in Self.everyCommand {
            let first = command.arguments.first ?? ""
            #expect(allowed.contains(first), "unexpected subcommand \"\(first)\" in \(command.arguments)")
        }
    }

    @Test("no argv element carries a destructive token")
    func noDestructiveTokens() {
        let forbidden = ["uninstall", "remove", "rm", "cleanup", "pin", "unpin", "zap", "--force",
                         "kill", "restart", "--all", "--file", "--sudo-service-user",
                         "--custom-remote", "--repair", "--eval-all", "untrust"]
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
            case .listFormulae:
                // The one read command that carries a kind token, and it must: without it brew
                // lists casks alongside formulae.
                #expect(arguments == ["list", "--formula", "--versions"])
            case .listCasks, .outdated, .update:
                #expect(!arguments.contains("--formula"))
            case .servicesList:
                #expect(arguments == ["services", "list", "--json"])
            case .serviceStart, .serviceStop:
                // Exactly one named service, no flags — `--all` would be a different blast radius.
                #expect(arguments.count == 3, "\(arguments)")
                #expect(!arguments.contains { $0.hasPrefix("-") })
            case .tap, .untap:
                // One named tap, nothing else: no --force (uninstalls packages!), no remotes.
                #expect(arguments.count == 2, "\(arguments)")
                #expect(!arguments.contains { $0.hasPrefix("-") })
            case .trustTap:
                // The explicit --tap type flag is the whole point (brew infers otherwise).
                #expect(arguments == ["trust", "--tap", "charmbracelet/tap"])
            }
        }
    }
}
