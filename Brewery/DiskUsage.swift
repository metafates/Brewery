//
//  DiskUsage.swift
//  Brewery
//

import Foundation

/// What an installed package occupies on disk, measured from the machine rather than guessed:
/// the API carries no sizes at all (bottle `files` entries hold `url` + `sha256` only, casks
/// nothing), so installed packages are the only ones a size can be honest for.
nonisolated enum DiskUsage {
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
