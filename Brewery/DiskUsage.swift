//
//  DiskUsage.swift
//  Brewery
//

import Foundation

/// What an installed package occupies on disk, measured from the machine rather than guessed:
/// the API carries no sizes at all (bottle `files` entries hold `url` + `sha256` only, casks
/// nothing), so installed packages are the only ones a size can be honest for.
nonisolated enum DiskUsage {
    /// v10.1 — measured sizes, keyed `"<package id>|<installed version>"` so an upgrade
    /// invalidates naturally. Session-lifetime and unbounded on purpose: one `Int64` per
    /// *visited* package is noise, and re-measuring a large keg on every card revisit was
    /// the cost worth killing — the redacted row only ever shows on a first visit.
    @MainActor static var cache: [String: Int64] = [:]

    /// The cache key for one package; the version makes an upgrade invalidate naturally.
    static func cacheKey(for id: Package.ID, version: String?) -> String {
        "\(id)|\(version ?? "")"
    }

    /// Cache-or-measure for one package's roots — the one memoized read behind the pane's
    /// Size row and the orphan bar's total.
    @MainActor static func measuredBytes(key: String, roots: [URL]) async -> Int64? {
        if let cached = cache[key] { return cached }
        guard let measured = await bytes(at: roots) else { return nil }
        cache[key] = measured
        return measured
    }
    /// Logical bytes under the given roots — regular files only, symlinks counted as links and
    /// never followed (a keg's bin links would double-count or escape the root). nil when no
    /// root exists: for an installed package that is a read failure, and "Zero bytes" would be
    /// a lie about it.
    ///
    /// `@concurrent` is load-bearing, as with `Receipts.sweep`: a large keg is tens of
    /// thousands of files, and a plain `nonisolated async` would walk them on the main actor.
    @concurrent static func bytes(at roots: [URL]) async -> Int64? {
        var total: Int64 = 0
        var found = false
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }
            found = true
            guard isDirectory.boolValue else {
                total += size(of: root)
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            while let item = enumerator?.nextObject() as? URL {
                total += size(of: item)
            }
        }
        return found ? total : nil
    }

    private static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }
}
