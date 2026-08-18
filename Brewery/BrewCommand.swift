//
//  BrewCommand.swift
//  Brewery
//
//  Created by vzbarashchenko on 10.08.2026.
//

import Foundation

/// The complete set of brew invocations this app can express.
///
/// Destructive operations are narrow and confirmed (v15); everything else stays unrepresentable,
/// not merely un-called: there is no `pin`, `--force` or `--ignore-dependencies` case, and no
/// way to pass raw arguments. Every removal — uninstall, zap, untap, autoremove, cleanup —
/// reaches the queue only after its confirmation dialog has run (the trust-write rule).
/// `BrewClient.run` takes only a `BrewCommand`, so this enum is the app's single source of
/// brew argv.
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
    // v10 — the first removal in the whitelist, and the least destructive one brew has: it
    // uninstalls only what brew itself computes as an unneeded dependency, takes no arguments
    // (nothing to aim it with), and the UI puts a confirmation dialog in front. `untap` set
    // the precedent for scoped, confirmed removals.
    case autoremove
    // v15 — uninstall joins under its own narrower bar: named but per-target-confirmed (the
    // dialog runs before AppModel.confirmedUninstall enqueues), kind-pinned like install, and
    // force-less — `--force` and `--ignore-dependencies` stay unrepresentable, so brew's own
    // dependents refusal fires before anything is removed. `zap` hard-codes `--cask` because
    // brew declares `conflicts "--formula", "--zap"` (cmd/uninstall.rb:38), and the UI offers
    // it only for casks whose receipt records a zap stanza.
    case uninstall(name: String, cask: Bool)
    case zap(name: String)
    // v19 — a read-only diagnostic, never queued: it runs inline like the state probes. The
    // hidden --json switch (cmd/doctor.rb:25-27) yields structured findings; the parser keeps
    // a raw-text fallback in case the flag ever changes shape. Exit 1 means findings exist,
    // not failure — the caller judges by parse, not exit code.
    case doctor
    // v18 — cleanup joins under autoremove's bar: argument-less by construction (no names, no
    // `--prune`, no `-s` representable), scoped to what brew itself computes as stale — old
    // kegs of installed formulae with linked/pinned/keepme versions kept (formula.rb:3657-3662),
    // version-stale downloads, logs older than 30 days — and confirmed before enqueue. The one
    // sharp edge is pre-dulled: plain `brew cleanup` would also autoremove packages
    // (cleanup.rb:412), but the app's standing HOMEBREW_NO_AUTOREMOVE=1 gates exactly that
    // line, so this command removes files, never packages.
    case cleanup

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
        case .autoremove:
            ["autoremove"]
        case let .uninstall(name, cask):
            ["uninstall", BrewCommand.kindFlag(cask: cask), name]
        case let .zap(name):
            ["uninstall", "--cask", "--zap", name]
        case .doctor:
            ["doctor", "--json"]
        case .cleanup:
            ["cleanup"]
        }
    }

    /// Mutating commands are serialized through the operation queue and get `SUDO_ASKPASS`.
    /// One exception (v8): `.update` — argument-less, non-destructive — may also run inline from
    /// the freshness check, which holds the queue's pump for its duration, so the serialization
    /// guarantee survives it.
    var isMutating: Bool {
        switch self {
        case .listFormulae, .listCasks, .outdated, .servicesList, .doctor:
            false
        case .update, .install, .upgrade, .upgradeAll, .serviceStart, .serviceStop, .tap, .untap, .trustTap, .untrustTap, .autoremove, .uninstall, .zap, .cleanup:
            true
        }
    }

    /// Service toggles change launchd state, not packages — they skip the session `brew update`
    /// the queue otherwise front-loads before the first mutation.
    var touchesPackages: Bool {
        switch self {
        // Service toggles change launchd state; tap/untap clone fresh checkouts; autoremove
        // and cleanup act on local kegs and cache files only — none of them benefit from a
        // `brew update` first. uninstall/zap stay in the default (true), unlike autoremove:
        // cask uninstall and zap dispatch stanzas from the *current* recipe, so fresh metadata
        // keeps what brew executes aligned with what the pane showed.
        case .serviceStart, .serviceStop, .tap, .untap, .trustTap, .untrustTap, .autoremove, .cleanup: false
        default: isMutating
        }
    }

    /// The app always knows the kind from the catalog, so brew never has to disambiguate a
    /// name that exists as both a formula and a cask.
    private static func kindFlag(cask: Bool) -> String {
        cask ? "--cask" : "--formula"
    }
}
