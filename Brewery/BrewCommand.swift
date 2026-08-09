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

    var arguments: [String] {
        switch self {
        case .listFormulae:
            ["list", "--versions"]
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
        }
    }

    /// Mutating commands are serialized through the operation queue and get `SUDO_ASKPASS`.
    var isMutating: Bool {
        switch self {
        case .listFormulae, .listCasks, .outdated:
            false
        case .update, .install, .upgrade, .upgradeAll:
            true
        }
    }

    /// The app always knows the kind from the catalog, so brew never has to disambiguate a
    /// name that exists as both a formula and a cask.
    private static func kindFlag(cask: Bool) -> String {
        cask ? "--cask" : "--formula"
    }
}
