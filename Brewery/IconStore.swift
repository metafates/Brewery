//
//  IconStore.swift
//  Brewery
//

import AppKit
import Foundation

/// Favicons for package homepages, keyed by **host** — many packages share one homepage host, so
/// deduping there is a large win over keying by package.
///
/// Three layers, checked in order: an in-memory `NSCache`, the disk directory, then the network.
/// The network fetch runs in a *shared task per host*, which is the whole point of this type: a
/// grid cell that scrolls away cancels its `await`, never the fetch, so the bytes still land in the
/// cache and the next appearance is a hit. `AsyncImage` cancelled the load itself, which is why
/// icons used to appear only after opening the detail sheet.
actor IconStore {
    static let shared = IconStore()

    /// Icons rarely change. A file older than this is still served — it is just refreshed behind
    /// the view — and it is also how long a negative marker suppresses re-asking.
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    /// The disk cache's sliding window of bytes. ~2,000 icons of ~4 KB is ~8 MB; this is headroom.
    static let byteCap = 50 * 1024 * 1024

    /// Slack before the LRU sweep runs again. Scanning the directory after literally every write
    /// would serialize the actor behind a `readdir` per icon on a cold launch; the directory can
    /// overshoot the cap by this much in between, which is noise against 50 MB.
    private static let sweepInterval = 1024 * 1024

    /// Starts full so the first write of a session always sweeps — otherwise a directory left over
    /// the cap by an earlier session could sit there through every short session that follows.
    private var unsweptBytes = IconStore.sweepInterval

    private let directory = CatalogStore.supportDirectory
        .appending(path: "Icons", directoryHint: .isDirectory)

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Memory → disk → network. Never throws and never blocks on a refresh.
    func icon(for host: String) async -> NSImage? {
        let key = Self.fileName(for: host)
        guard !key.isEmpty else { return nil }

        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let entry = read(key) {
            if let image = entry.image { memory.setObject(image, forKey: key as NSString) }
            // Stale-while-revalidate: hand back what we have, refresh out of band.
            if !entry.fresh { _ = fetch(host: host, key: key) }
            return entry.image
        }

        return await fetch(host: host, key: key).value
    }

    // MARK: - Pure helpers

    /// Which files to delete to bring the directory back under `cap`: oldest access first, stopping
    /// the moment the total fits. Plain LRU over file mtimes — no index file, no database.
    nonisolated static func evictions(_ files: [(name: String, size: Int, mtime: Date)],
                                      cap: Int) -> [String] {
        var total = files.reduce(0) { $0 + $1.size }
        guard total > cap else { return [] }

        var doomed: [String] = []
        for file in files.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > cap else { break }
            doomed.append(file.name)
            total -= file.size
        }
        return doomed
    }

    /// Whether a cached file is still within its TTL. A birthtime in the future can only come from
    /// a clock change, and would otherwise pin the entry forever — so it counts as expired.
    nonisolated static func isMarkerFresh(birthtime: Date, now: Date, ttl: TimeInterval) -> Bool {
        (0...ttl).contains(now.timeIntervalSince(birthtime))
    }

    /// Hosts become file names, so anything that could escape the directory is folded to `_`.
    /// A name made of nothing but dots is rejected outright rather than sanitized into `_`.
    nonisolated static func fileName(for host: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")
        let cleaned = String(host.lowercased().map { allowed.contains($0) ? $0 : "_" })
        guard cleaned.contains(where: { $0 != "." }) else { return "" }
        return String(cleaned.prefix(200))
    }

    nonisolated static func faviconURL(host: String) -> URL? {
        URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }

    // MARK: - Disk

    private struct Entry {
        let image: NSImage?   // nil for a zero-byte negative marker
        let fresh: Bool
    }

    private func fileURL(_ key: String) -> URL {
        directory.appending(path: key, directoryHint: .notDirectory)
    }

    /// birthtime answers "how old is this?", mtime answers "when was it last wanted?" — so reading
    /// touches mtime and leaves birthtime alone.
    private func read(_ key: String) -> Entry? {
        let url = fileURL(key)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
              let size = values.fileSize else { return nil }

        let fresh = Self.isMarkerFresh(birthtime: values.creationDate ?? .distantPast,
                                       now: .now,
                                       ttl: Self.ttl)
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)

        // Zero bytes is the negative marker: it renders as our SF Symbol fallback, never as
        // DuckDuckGo's stand-in globe, because empty data simply cannot decode.
        guard size > 0 else { return Entry(image: nil, fresh: fresh) }

        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            // A file we cannot decode is worse than no file — drop it and let the fetch run.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Entry(image: image, fresh: fresh)
    }

    private func write(_ bytes: Data, key: String) {
        let url = fileURL(key)
        guard (try? bytes.write(to: url, options: .atomic)) != nil else { return }
        // An atomic write replaces the file, and a replacement can inherit the old birthtime —
        // which would make a refreshed marker immortal. Stamp both dates explicitly.
        let now = Date.now
        try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now],
                                               ofItemAtPath: url.path)

        unsweptBytes += bytes.count
        guard unsweptBytes >= Self.sweepInterval else { return }
        unsweptBytes = 0
        sweep()
    }

    private func sweep() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: keys)
        else { return }

        let files = contents.compactMap { url -> (name: String, size: Int, mtime: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else { return nil }
            return (url.lastPathComponent, size, mtime)
        }

        for name in Self.evictions(files, cap: Self.byteCap) {
            try? FileManager.default.removeItem(at: fileURL(name))
        }
    }

    // MARK: - Network

    /// One task per host, shared by every caller — and deliberately unstructured, so no caller's
    /// cancellation can reach it.
    private func fetch(host: String, key: String) -> Task<NSImage?, Never> {
        if let existing = inFlight[key] { return existing }

        let task = Task {
            let bytes = await Self.download(host: host)
            return self.finish(key: key, bytes: bytes)
        }
        inFlight[key] = task
        return task
    }

    private func finish(key: String, bytes: Data?) -> NSImage? {
        inFlight[key] = nil
        // nil means we never got an answer (offline, DNS): retry next launch rather than poison
        // the cache with a week-long marker.
        guard let bytes else { return nil }

        let image = bytes.isEmpty ? nil : NSImage(data: bytes)
        write(image == nil ? Data() : bytes, key: key)
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    /// Empty data means "the host answered, and the answer is no icon" — an HTTP error or a body
    /// we cannot decode. That earns a marker; a transport failure (nil) does not.
    private static func download(host: String) async -> Data? {
        guard let url = faviconURL(host: host) else { return Data() }
        // Icons no longer route through URLCache: this store *is* the cache.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return Data()
        }
        return data
    }
}
