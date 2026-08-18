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
        #expect(BrewCommand.untrustTap(name: "charmbracelet/tap").arguments
                == ["untrust", "--tap", "charmbracelet/tap"])
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
        .untrustTap(name: "charmbracelet/tap"),
        .autoremove,
        .uninstall(name: "wget", cask: false),
        .uninstall(name: "iterm2", cask: true),
        .zap(name: "iterm2"),
        .cleanup,
        .doctor,
        .link(name: "deno"),
    ] }

    /// One tag per `BrewCommand` case. The switch is exhaustive on purpose: adding a case to
    /// `BrewCommand` stops this file compiling until the case is tagged *and* added to
    /// `everyCommand`, so the tripwire below can never silently miss a new command.
    enum CommandKind: CaseIterable {
        case listFormulae, listCasks, outdated, update, install, upgrade, upgradeAll
        case servicesList, serviceStart, serviceStop, tap, untap, trustTap, untrustTap
        case autoremove, uninstall, zap, cleanup, doctor, link
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
        case .untrustTap: .untrustTap
        case .autoremove: .autoremove
        case .uninstall: .uninstall
        case .zap: .zap
        case .cleanup: .cleanup
        case .doctor: .doctor
        case .link: .link
        }
    }

    @Test("the tripwire covers every case of the enum")
    func everyCommandIsCovered() {
        #expect(Set(Self.everyCommand.map(Self.commandKind)) == Set(CommandKind.allCases))
    }

    @Test("first argv token is on the whitelist")
    func firstTokenIsWhitelisted() {
        // `autoremove` was the first removal admitted: argument-less by construction
        // (nothing to aim it with), scoped to what brew itself computes as unneeded, and
        // confirmed in the UI before it is ever enqueued. v15 admits `uninstall` under its
        // own narrower bar: named but per-target-confirmed (the dialog runs before the
        // model enqueues), kind-pinned like install, force-less (no `--force`, no
        // `--ignore-dependencies` — brew's dependents refusal fires before anything is
        // removed), and its `remove`/`rm` aliases stay banned: one spelling, one case.
        // v18 admits `cleanup` under autoremove's exact bar: argument-less by construction
        // (no `--prune`, no `-s`, no names representable), scoped to what brew itself computes
        // as stale (linked/pinned/keepme kegs are kept), confirmed in the UI before enqueue —
        // and files-only, because the app's standing HOMEBREW_NO_AUTOREMOVE=1 gates the
        // autoremove cleanup would otherwise run (cleanup.rb:412).
        // v19 admits `doctor` as a read: strictly diagnostic, never queued, exit 1 means
        // findings exist rather than failure.
        // v21 admits `link`: named but non-destructive — bare link creates symlinks, refuses
        // conflicts and rolls back (keg.rb:574-576); `--overwrite` (the deleting variant) is
        // in the forbidden list below; names come verbatim from doctor's own remediation.
        let allowed: Set<String> = ["list", "outdated", "update", "install", "upgrade", "services", "tap", "untap", "trust", "untrust", "autoremove", "uninstall", "cleanup", "doctor", "link"]
        for command in Self.everyCommand {
            let first = command.arguments.first ?? ""
            #expect(allowed.contains(first), "unexpected subcommand \"\(first)\" in \(command.arguments)")
        }
    }

    @Test("autoremove is exactly one word — no target can ever ride along")
    func autoremoveArgv() {
        #expect(BrewCommand.autoremove.arguments == ["autoremove"])
    }

    @Test("doctor is a read: structured output, never queued")
    func doctorArgv() {
        #expect(BrewCommand.doctor.arguments == ["doctor", "--json"])
        #expect(BrewCommand.doctor.isMutating == false)
    }

    @Test("link: exact argv, hostile names stay one element, acts on local kegs")
    func linkArgv() {
        #expect(BrewCommand.link(name: "deno").arguments == ["link", "deno"])
        #expect(BrewCommand.link(name: "deno").isMutating)
        #expect(BrewCommand.link(name: "deno").touchesPackages == false)
        let hostile = "deno; rm -rf /"
        #expect(BrewCommand.link(name: hostile).arguments == ["link", hostile])
    }

    @Test("cleanup is exactly one word — no prune, no scrub, no names can ever ride along")
    func cleanupArgv() {
        #expect(BrewCommand.cleanup.arguments == ["cleanup"])
        #expect(BrewCommand.cleanup.isMutating)
        // Acts on local kegs and cache files — no session brew update first (autoremove's rule).
        #expect(BrewCommand.cleanup.touchesPackages == false)
    }

    @Test("no argv element carries a destructive token")
    func noDestructiveTokens() {
        // v15: "uninstall" left this list when it joined the whitelist (its shape is pinned in
        // `explicitKindToken` and `zapArgv` instead); "--ignore-dependencies" joined it. Bare
        // "zap" stays: the match rule below is exact-or-`zap-`/`zap=`, so the `.zap` case's
        // `--zap` flag never trips it — the entry bans any argv element *being* the word.
        // v18: "cleanup" left the list the same way (argv pinned to exactly ["cleanup"] in
        // `cleanupArgv`/`explicitKindToken`). The v5 ban on `services cleanup` (deletes plists)
        // survives structurally: the services argvs are pinned flag-less with canonical verbs,
        // so "cleanup" can never appear as a services subcommand. "--prune" and "--scrub"/"-s"
        // join the ban so no future case can widen cleanup's blast radius.
        let forbidden = ["remove", "rm", "pin", "unpin", "zap", "--force",
                         "--ignore-dependencies", "kill", "restart", "--all", "--file",
                         "--prune", "--scrub", "-s", "--overwrite", "--dry-run",
                         "--sudo-service-user", "--custom-remote", "--repair", "--eval-all"]
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
            case .trustTap, .untrustTap:
                // The explicit --tap type flag is the whole point (brew infers otherwise).
                #expect(arguments.count == 3)
                #expect(arguments[1] == "--tap")
            case .autoremove:
                // One word, ever: an argument would be a target, and it has none to take.
                #expect(arguments == ["autoremove"])
            case .uninstall:
                // Exactly like install: explicit kind token, one name, nothing else — no
                // --force, no --ignore-dependencies, so brew's dependents refusal can fire.
                #expect(arguments.count == 3, "\(arguments)")
                #expect(arguments.first == "uninstall")
                #expect(arguments[1] == "--formula" || arguments[1] == "--cask",
                        "\(arguments) has no explicit kind token")
            case .zap:
                // Order pinned exactly, and never --formula: brew declares
                // `conflicts "--formula", "--zap"` (cmd/uninstall.rb:38).
                #expect(arguments.count == 4, "\(arguments)")
                #expect(Array(arguments.prefix(3)) == ["uninstall", "--cask", "--zap"])
                #expect(!arguments.contains("--formula"))
            case .cleanup:
                // One word, ever: a name would narrow it to per-formula mode, a flag would
                // widen what it deletes (`--prune=all` wipes the whole cache). Neither exists.
                #expect(arguments == ["cleanup"])
            case .doctor:
                #expect(arguments == ["doctor", "--json"])
            case .link:
                // Two tokens, no flags — `--overwrite` (deletes files) and `--force`
                // (keg-only override) must stay unrepresentable.
                #expect(arguments.count == 2, "\(arguments)")
                #expect(arguments.first == "link")
                #expect(!arguments.contains { $0.hasPrefix("-") })
            }
        }
    }

    // MARK: - Uninstall (v15)

    @Test("uninstall/zap: exact argv, kind-pinned, force-less")
    func uninstallArguments() {
        #expect(BrewCommand.uninstall(name: "wget", cask: false).arguments == ["uninstall", "--formula", "wget"])
        #expect(BrewCommand.uninstall(name: "iterm2", cask: true).arguments == ["uninstall", "--cask", "iterm2"])
        #expect(BrewCommand.zap(name: "iterm2").arguments == ["uninstall", "--cask", "--zap", "iterm2"])
        #expect(BrewCommand.uninstall(name: "wget", cask: false).isMutating)
        #expect(BrewCommand.zap(name: "iterm2").isMutating)
        // Unlike autoremove: cask uninstall/zap dispatch stanzas from the current recipe,
        // so they take the session brew update.
        #expect(BrewCommand.uninstall(name: "wget", cask: false).touchesPackages)
        #expect(BrewCommand.zap(name: "iterm2").touchesPackages)
    }

    @Test("uninstall names pass through as one argv element, qualified or hostile")
    func uninstallNameIsOneArgument() {
        let hostile = "wget; rm -rf /"
        #expect(BrewCommand.uninstall(name: hostile, cask: false).arguments == ["uninstall", "--formula", hostile])
        #expect(BrewCommand.zap(name: hostile).arguments == ["uninstall", "--cask", "--zap", hostile])

        let qualified = BrewCommand.uninstall(name: "charmbracelet/tap/gum", cask: false)
        #expect(qualified.arguments == ["uninstall", "--formula", "charmbracelet/tap/gum"])
        #expect(qualified.arguments.count == 3)
    }
}
