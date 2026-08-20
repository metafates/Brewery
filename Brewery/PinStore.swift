//
//  PinStore.swift
//  Brewery
//

import Foundation

/// Reads brew's pin ledgers: two plain directories under `var/homebrew` whose entries are
/// bare-short-name symlinks into the pinned keg (`formula_pin.rb:15`, `cask/cask.rb:347`).
/// Every brew producer resolves pins exactly this way, which makes the scan the app's truth —
/// unlike the outdated payload's `pinned` flag, it also covers pins on current packages.
nonisolated enum PinStore {
    /// The pinned package IDs under the given prefix; empty on nil or when a directory is
    /// missing (brew creates them lazily and removes them when empty — absence means zero
    /// pins, not an error). Per-kind dangling semantics follow brew's own predicates: a
    /// formula is pinned while the symlink *exists* — dangling still blocks upgrade and
    /// uninstall (`formula_pin.rb:40-42`) — while a cask needs the target too
    /// (`cask/cask.rb:329-331`). `@concurrent` for the probe shape it shares with its
    /// refresh siblings.
    @concurrent static func scan(prefix: URL?) async -> Set<Package.ID> {
        guard let prefix else { return [] }
        var result: Set<Package.ID> = []
        let base = prefix.appending(path: "var/homebrew", directoryHint: .isDirectory)
        for (directory, kind) in [("pinned", PackageKind.formula), ("pinned_casks", .cask)] {
            let root = base.appending(path: directory, directoryHint: .isDirectory)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let path = entry.path(percentEncoded: false)
                // lstat-based, so it answers for dangling links too — and a stray regular
                // file (.DS_Store) is not a pin.
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
                else { continue }
                if kind == .cask, !FileManager.default.fileExists(atPath: path) { continue }
                result.insert(Package.packageID(kind: kind, name: entry.lastPathComponent))
            }
        }
        return result
    }
}
