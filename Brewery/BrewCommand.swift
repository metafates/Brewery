//
//  BrewCommand.swift
//  Brewery
//
//  Created by vzbarashchenko on 10.08.2026.
//

import Foundation

/// The complete set of brew invocations this app can express.
///
/// Destructive operations are unrepresentable, not merely un-called: there is no `uninstall`,
/// `cleanup`, `pin`, `zap` or `--force` case, and no way to pass raw arguments. `BrewClient.run`
/// takes only a `BrewCommand`, so this enum is the app's single source of brew argv.
nonisolated enum BrewCommand: Equatable, Hashable {
    case listFormulae
    case listCasks
    case outdated
    case update
    case install(name: String, cask: Bool)
    case upgrade(name: String, cask: Bool)
    case upgradeAll
    // v5 — canonical service verbs only. `kill`, `cleanup` (deletes plists), `restart`, `run`,
    // their aliases, `--all`, `--file=` and `--sudo-service-user` stay unrepresentable; start
    // and stop are the reversible pair brew itself defines as each other's inverse.
    case servicesList
    case serviceStart(name: String)
    case serviceStop(name: String)
    // v6 — a tap is a git clone of github.com/user/homebrew-repo; untap removes the clone and
    // refuses by itself while the tap's packages are installed. `untap --force` (which would
    // uninstall those packages), `--custom-remote`, `--repair` and `--eval-all` are
    // unrepresentable.
    case tap(name: String)
    case untap(name: String)
    // v6 — the only trust writes besides brew's own install-time auto-trust: whole-tap trust
    // (granted through an explicit confirmation) and its inverse. Both carry the explicit
    // --tap type flag; per-item trust stays brew's own business.
    case trustTap(name: String)
    case untrustTap(name: String)

    var arguments: [String] {
        switch self {
        case .listFormulae:
            // `--formula` is not redundant: bare `brew list --versions` prints casks too, which
            // would enter the overlay under bogus `formula:<token>` keys.
            ["list", "--formula", "--versions"]
        case .listCasks:
            ["list", "--cask", "--versions"]
        case .outdated:
            ["outdated", "--json=v2"]
        case .update:
            ["update"]
        case let .install(name, cask):
            ["install", BrewCommand.kindFlag(cask: cask), name]
        case let .upgrade(name, cask):
            ["upgrade", BrewCommand.kindFlag(cask: cask), name]
        case .upgradeAll:
            ["upgrade"]
        case .servicesList:
            ["services", "list", "--json"]
        case let .serviceStart(name):
            ["services", "start", name]
        case let .serviceStop(name):
            ["services", "stop", name]
        case let .tap(name):
            ["tap", name]
        case let .untap(name):
            ["untap", name]
        case let .trustTap(name):
            // The explicit type flag is required: without it brew infers the target type by
            // scanning tap files and can raise on ambiguity.
            ["trust", "--tap", name]
        case let .untrustTap(name):
            ["untrust", "--tap", name]
        }
    }

    /// Mutating commands are serialized through the operation queue and get `SUDO_ASKPASS`.
    var isMutating: Bool {
        switch self {
        case .listFormulae, .listCasks, .outdated, .servicesList:
            false
        case .update, .install, .upgrade, .upgradeAll, .serviceStart, .serviceStop, .tap, .untap, .trustTap, .untrustTap:
            true
        }
    }

    /// Service toggles change launchd state, not packages — they skip the session `brew update`
    /// the queue otherwise front-loads before the first mutation.
    var touchesPackages: Bool {
        switch self {
        // Service toggles change launchd state; tap/untap clone fresh checkouts — none of them
        // benefit from a `brew update` first.
        case .serviceStart, .serviceStop, .tap, .untap, .trustTap, .untrustTap: false
        default: isMutating
        }
    }

    /// The app always knows the kind from the catalog, so brew never has to disambiguate a
    /// name that exists as both a formula and a cask.
    private static func kindFlag(cask: Bool) -> String {
        cask ? "--cask" : "--formula"
    }
}
