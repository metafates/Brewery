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

    /// In-flight measurements by key: the pane's Size row, the orphan bar and the size sweep
    /// can ask for the same keg concurrently, and check-then-act across the await let both
    /// miss and both walk. Unstructured and uncancellable like IconStore's fetch — a pane
    /// closing mid-walk must not abandon a measurement other callers await.
    @MainActor private static var inFlight: [String: Task<Int64?, Never>] = [:]

    /// Cache-or-measure for one package's roots — the one memoized read behind the pane's
    /// Size row and the orphan bar's total.
    @MainActor static func measuredBytes(key: String, roots: [URL]) async -> Int64? {
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task {
            let measured = await bytes(at: roots)
            if let measured { cache[key] = measured }
            inFlight[key] = nil
            return measured
        }
        inFlight[key] = task
        return await task.value
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
        var visited = 0
        for root in roots {
            guard !Task.isCancelled else { return nil }
            // One resourceValues read answers exists/directory/size at once; a missing or
            // dangling root throws and is skipped, the old fileExists probe's behavior.
            guard let values = try? root.resourceValues(forKeys:
                [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
            found = true
            guard values.isDirectory == true else {
                total += values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            while let item = enumerator?.nextObject() as? URL {
                // A large keg is tens of thousands of files; a cancelled caller (the Storage
                // bar's direct cache/logs walks) should stop paying for an answer nobody
                // will read. nil, never a truncated total.
                visited += 1
                if visited % 512 == 0, Task.isCancelled { return nil }
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
