//
//  IconStore.swift
//  Brewery
//

import AppKit
import Foundation

/// Favicons for package homepages, keyed by **host** — many packages share one homepage host, so
/// deduping there is a large win over keying by package.
///
/// Three layers, checked in order: an in-memory dictionary, the disk directory, then the network.
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

    /// How long a host that failed to *answer at all* is left alone. A transport failure earns no
    /// disk marker (it says nothing about the host), but without some backoff every reappearance of
    /// the card re-fires the request — which on a network where the icon host resolves slowly means
    /// the grid spends forever re-asking questions it already knows time out.
    private static let retryDelay: TimeInterval = 5 * 60

    /// mtime is the LRU clock, and LRU does not need second precision. Re-stamping it on every read
    /// costs a write syscall per icon per appearance, serialized behind this actor.
    private static let touchInterval: TimeInterval = 24 * 60 * 60

    private var failedAt: [String: Date] = [:]

    /// Icons are decoration: a slow lookup must never hold a connection slot the way the default
    /// 60 s timeout does. Its own session so these limits cannot affect catalog downloads.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Every icon comes from one host, so only the session's first lookup can be slow — after it
        // resolves, the OS has the answer. The budget therefore has to outlast one bad resolution
        // (a resolver that falls back takes ~5 s here) or no icon ever loads; what keeps the UI free
        // is the concurrency cap, not a short timeout.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    private let directory = CatalogStore.supportDirectory
        .appending(path: "Icons", directoryHint: .isDirectory)

    /// `AsyncImage` threw a scrolled-away load away, which capped how much could ever be in flight.
    /// Not cancelling is what fixes icons-only-load-after-clicking, but it removes that cap, so the
    /// cap has to come from somewhere: at most this many downloads run at once and the rest queue.
    private static let maxConcurrentFetches = 6

    /// A plain dictionary, not `NSCache`: the system purges an `NSCache` on memory pressure with no
    /// warning, and this app holds a 16k catalog, so icons were being evicted and re-read from disk
    /// every time a card was opened. Icons are ~4 KB, so a few hundred of them cost about a megabyte.
    /// ponytail: flushes wholesale at the cap instead of evicting LRU — the disk cache is right
    /// behind it, so the ceiling is one re-read, not a re-fetch. Swap in an LRU if that ever shows up.
    private static let memoryLimit = 1500
    private var memory: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var activeFetches = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Memory → disk → network. Never throws and never blocks on a refresh.
    func icon(for host: String) async -> NSImage? {
        let key = Self.fileName(for: host)
        guard !key.isEmpty else { return nil }

        if let cached = memory[key] { return cached }

        if let entry = read(key) {
            if let image = entry.image { remember(image, key: key) }
            // Stale-while-revalidate: hand back what we have, refresh out of band.
            if !entry.fresh, !isCoolingDown(key) { _ = fetch(host: host, key: key) }
            return entry.image
        }

        // A host that just failed to answer gets left alone rather than re-asked on every
        // reappearance of the card — otherwise a resolver that times out costs the grid the same
        // stall over and over for as long as the user scrolls.
        guard !isCoolingDown(key) else { return nil }

        return await fetch(host: host, key: key).value
    }

    private func remember(_ image: NSImage, key: String) {
        if memory.count >= Self.memoryLimit { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
    }

    private func isCoolingDown(_ key: String) -> Bool {
        guard let failed = failedAt[key] else { return false }
        guard Date.now.timeIntervalSince(failed) < Self.retryDelay else {
            failedAt[key] = nil
            return false
        }
        return true
    }

    /// A plain async semaphore. The slot is handed straight to the next waiter rather than released
    /// and re-taken, so a queued host cannot be overtaken by a fresh caller.
    private func acquireSlot() async {
        guard activeFetches >= Self.maxConcurrentFetches else {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if waiting.isEmpty {
            activeFetches -= 1
        } else {
            waiting.removeFirst().resume()
        }
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
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey,
                                                            .contentModificationDateKey]),
              let size = values.fileSize else { return nil }

        let now = Date.now
        let fresh = Self.isMarkerFresh(birthtime: values.creationDate ?? .distantPast,
                                       now: now,
                                       ttl: Self.ttl)
        // Only re-stamp a clock the LRU reads in days. Touching on every read costs one write
        // syscall per icon per appearance, all of it serialized behind this actor.
        if let accessed = values.contentModificationDate,
           now.timeIntervalSince(accessed) > Self.touchInterval {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }

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
            await self.acquireSlot()
            let bytes = await Self.download(host: host)
            self.releaseSlot()
            return self.finish(key: key, bytes: bytes)
        }
        inFlight[key] = task
        return task
    }

    private func finish(key: String, bytes: Data?) -> NSImage? {
        inFlight[key] = nil
        // nil means we never got an answer (offline, slow DNS). That says nothing about the host, so
        // it earns no week-long disk marker — just a short in-memory cooldown, so the grid stops
        // re-asking a question that is currently timing out.
        guard let bytes else {
            failedAt[key] = .now
            return nil
        }
        failedAt[key] = nil

        let image = bytes.isEmpty ? nil : NSImage(data: bytes)
        write(image == nil ? Data() : bytes, key: key)
        if let image { remember(image, key: key) }
        return image
    }

    /// Empty data means "the host answered, and the answer is no icon" — an HTTP error or a body
    /// we cannot decode. That earns a marker; a transport failure (nil) does not.
    private static func download(host: String) async -> Data? {
        guard let url = faviconURL(host: host) else { return Data() }
        // Icons no longer route through URLCache: this store *is* the cache.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return Data()
        }
        return data
    }
}
