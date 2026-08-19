//
//  StateSnapshot.swift
//  Brewery
//

import Foundation

/// The last-known install state, persisted so launch shows the previous session's truth
/// instead of flashing every card "Install" for the second the first probes take. Written at
/// every `refreshState()` publish, applied by `bootstrap()` before the first frame; the probes
/// then correct it silently — the same stale-until-refresh rule the app already runs
/// mid-session, stretched across the relaunch gap.
nonisolated struct StateSnapshot: Codable {
    /// Own schema stamp, independent of `CatalogStore.cacheVersion` (which covers `Package`'s
    /// shape): bump when `InstalledInfo`/`OutdatedInfo`/`ServiceStatus` change stored shape.
    /// A mismatch reads as no snapshot — first-launch behavior.
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var installed: [Package.ID: InstalledInfo]
    var outdated: [Package.ID: OutdatedInfo]
    var serviceStatuses: [String: ServiceStatus]

    static var fileURL: URL {
        CatalogStore.supportDirectory.appending(path: "state.json", directoryHint: .notDirectory)
    }

    /// nil when absent, on a version mismatch, or when decoding throws — all read as "no
    /// snapshot". Migration is simply the next refresh writing the current shape.
    static func load(from url: URL = fileURL) -> StateSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(StateSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    /// Best effort — a snapshot we cannot write costs the next launch its head start, nothing more.
    @concurrent func save(to url: URL = Self.fileURL) async {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
