//
//  BrewClient.swift
//  Brewery
//

import Foundation
import Observation

enum BrewError: Error {
    case notFound
    case cancelled
    case failed(exitCode: Int32)
}

/// Finds the brew binary and runs whitelisted commands, streaming their output line by line.
@Observable
final class BrewClient {
    private static let candidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    private(set) var path: URL?

    var isAvailable: Bool { path != nil }

    /// HOMEBREW_PREFIX, derived as the brew binary's grandparent directory — the same rule
    /// `bin/brew` uses (`HOMEBREW_PREFIX="${HOMEBREW_BREW_FILE%/*/*}"`).
    var prefix: URL? { path?.deletingLastPathComponent().deletingLastPathComponent() }

    /// HOMEBREW_REPOSITORY — where `Library/Taps` lives. Same grandparent rule but through the
    /// symlink: on Intel, `/usr/local/bin/brew` links into `/usr/local/Homebrew`, so repository
    /// and prefix differ there; on Apple silicon they coincide.
    var repository: URL? { path?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent() }

    init() {
        discover()
        // Warm the login-shell capture so it overlaps bootstrap's snapshot/cache load;
        // the first brew child then awaits an already-resolved task in the common case.
        Task { _ = await shellEnvironment() }
    }

    // MARK: - Login-shell overlay

    private var overlayTask: Task<[String: String], Never>?

    /// Resolved copy for synchronous readers; empty until capture completes or when it failed.
    private(set) var shellOverlay: [String: String] = [:]

    /// The login-shell overlay, captured once per launch. The task is created synchronously on
    /// first access, so concurrent callers (bootstrap's parallel probes) all await one capture.
    func shellEnvironment() async -> [String: String] {
        // Under the harness the developer's dotfiles must not run — and the overlay would
        // shadow the XCUITest launch environment in the merge, defeating the fixture root's
        // XDG_CONFIG_HOME/HOMEBREW_CACHE/HOMEBREW_LOGS siblings.
        guard !UITestMode.active else { return [:] }
        if let overlayTask { return await overlayTask.value }
        let task = Task {
            let overlay = await LoginEnvironment.capture()
            shellOverlay = overlay
            return overlay
        }
        overlayTask = task
        return await task.value
    }

    /// The environment the *next* brew child gets — which is therefore the environment the
    /// freshness and storage helpers must resolve HOMEBREW_CACHE/LOGS against.
    var effectiveEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(shellOverlay) { _, shell in shell }
    }

    /// Apple silicon prefix first, then Intel. Re-run on ⌘R so installing brew needs no relaunch.
    func discover() {
        // A harness launch can never reach the real brew: the fake path is the only candidate,
        // and its absence (a brew-missing scenario) reads as not installed.
        if UITestMode.active {
            path = UITestMode.brewPath
            return
        }
        let existing = Self.candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
        path = existing.map { URL(filePath: $0) }
    }

    // MARK: - Invocation

    /// Core exec. Streams every stdout and stderr line to `onLine`, returns brew's exit code.
    /// `OnErrorLine` splits stderr into its own sink when set (doctor's JSON must not
    /// interleave with stderr noise); nil keeps the historical merged stream for every other
    /// caller.
    func run(_ command: BrewCommand,
             onLine: @MainActor @Sendable @escaping (String) -> Void,
             onErrorLine: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> Int32 {
        guard let executable = path else { throw BrewError.notFound }
        let overlay = await shellEnvironment()

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        process.environment = Self.environment(for: command, overlay: overlay)
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let signals = SignalGate()
        var readers: [Task<Void, Never>] = []
        let (drained, drainSignal) = AsyncStream<Void>.makeStream()

        let code: Int32 = try await withTaskCancellationHandler {
            // Exit is awaited through the termination handler rather than `waitUntilExit`: that call
            // would block this actor, the @MainActor `onLine` callbacks could never run, the 64 KB
            // pipe buffer would fill and brew would block on write, so nothing would ever exit.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    signals.disarm()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: BrewError.notFound)
                    return
                }
                signals.arm(process)
                // Unstructured on purpose: these must keep draining after cancellation, or brew
                // blocks writing its interrupt cleanup into a full pipe and never terminates.
                readers = [
                    Task {
                        await Self.forward(output.fileHandleForReading, to: onLine)
                        drainSignal.yield()
                    },
                    Task {
                        await Self.forward(errors.fileHandleForReading, to: onErrorLine ?? onLine)
                        drainSignal.yield()
                    },
                ]
            }
        } onCancel: {
            signals.interrupt()
        }

        // Both streams reach EOF before the caller sees the exit code, so no line is lost — but
        // bounded: EOF needs the *last* descendant holding the pipe to close it, and a cask
        // postinstall that leaves a background process behind would otherwise wedge this call, and
        // the serialized queue behind it, forever. In an unstructured task so that a cancelled
        // operation still collects brew's interrupt-cleanup lines.
        await Task { await Self.drain(drained, expecting: readers.count, grace: .seconds(2)) }.value
        for reader in readers { reader.cancel() }

        if code == 130 { throw BrewError.cancelled }
        if process.terminationReason == .uncaughtSignal, Task.isCancelled { throw BrewError.cancelled }
        return code
    }

    /// Runs and accumulates output; throws `BrewError.failed` on a non-zero exit.
    func capture(_ command: BrewCommand) async throws -> String {
        let buffer = LineBuffer()
        let code = try await run(command) { buffer.lines.append($0) }
        guard code == 0 else { throw BrewError.failed(exitCode: code) }
        return buffer.lines.joined(separator: "\n")
    }

    /// Waits for `count` readers to signal EOF, giving up after `grace` — a leaked descriptor then
    /// costs a couple of seconds instead of the session. Both racers are cancellable, so the group
    /// always unwinds; readers that never finish are abandoned (and cancelled by the caller).
    private static func drain(_ signals: AsyncStream<Void>, expecting count: Int, grace: Duration) async {
        guard count > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var seen = 0
                for await _ in signals {
                    seen += 1
                    if seen == count { return }
                }
            }
            group.addTask { try? await Task.sleep(for: grace) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func forward(_ handle: FileHandle,
                                to onLine: @MainActor @Sendable @escaping (String) -> Void) async {
        do {
            for try await line in handle.bytes.lines {
                onLine(line)
            }
        } catch {
            // A read error just ends the stream early; the exit code decides success.
        }
    }

    private static func environment(for command: BrewCommand,
                                    overlay: [String: String]) -> [String: String] {
        var environment = merged(base: ProcessInfo.processInfo.environment,
                                 overlay: overlay,
                                 askpass: command.isMutating ? askpassPath() : nil)
        // The dump's destination, kept out of argv on purpose (see `BrewCommand.bundleDump`).
        // Scoped to the one command, like `SUDO_ASKPASS` above: `brew bundle` is the only
        // reader, but a stray `HOMEBREW_BUNDLE_FILE` on every child is a claim about the
        // user's Brewfile that this app has no business making.
        if command == .bundleDump {
            environment["HOMEBREW_BUNDLE_FILE"] = "/dev/stdout"
        }
        return environment
    }

    /// Merge order is the contract: the GUI base, then the login-shell overlay (terminal
    /// parity — a shell HOMEBREW_CACHE must reach the child), then the app's forced vars last,
    /// because they are safety guarantees and must beat any shell export.
    static func merged(base: [String: String],
                       overlay: [String: String],
                       askpass: String?) -> [String: String] {
        var environment = base.merging(overlay) { _, shell in shell }
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_ASK"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        // `Brew uninstall` implicitly autoremoves afterwards (cmd/uninstall.rb:133); a
        // removal must be exactly what the user chose. Orphans surface in the Orphans report
        // instead. The explicit `.autoremove` command is unaffected (cmd/autoremove.rb calls
        // Cleanup.autoremove directly).
        environment["HOMEBREW_NO_AUTOREMOVE"] = "1"
        // Services-only: silences a stderr domain warning that fires whenever uid ≠ euid.
        environment["HOMEBREW_SERVICES_NO_DOMAIN_WARNING"] = "1"
        if let askpass {
            environment["SUDO_ASKPASS"] = askpass
        }
        return environment
    }

    // MARK: - Metadata freshness

    /// brew's own API refresh window (`HOMEBREW_API_AUTO_UPDATE_SECS` default, env_config.rb:57).
    /// Metadata younger than this is exactly what a terminal `brew outdated` would settle for.
    static let metadataWindow: TimeInterval = 450

    /// When brew last had known-good API metadata: the newest mtime among the internal payloads.
    /// brew touches that mtime only after a successful download or revalidation (api.rb:141-146),
    /// so terminal-side updates count too. nil — no payload at all — reads as maximally stale.
    func metadataDate() -> Date? {
        Self.newestMetadataDate(in: Self.apiDirectory(
            environment: effectiveEnvironment,
            home: URL.homeDirectory))
    }

    /// The cache directory brew will use for the processes *we* spawn: the inherited
    /// `HOMEBREW_CACHE` override if the GUI environment carries one, else the macOS default
    /// (utils/os.sh:55). What `brew cleanup` sweeps is this directory — measuring anything
    /// else would inventory files cleanup will never touch.
    nonisolated static func cacheDirectory(environment: [String: String], home: URL) -> URL {
        environment["HOMEBREW_CACHE"].map { URL(filePath: $0) }
            ?? home.appending(path: "Library/Caches/Homebrew")
    }

    /// Same rule for logs (utils/os.sh:56, `HOMEBREW_LOGS` override honored). Cleanup removes
    /// log subdirectories older than 30 days (cleanup.rb:541 — min(days, 30)).
    nonisolated static func logsDirectory(environment: [String: String], home: URL) -> URL {
        environment["HOMEBREW_LOGS"].map { URL(filePath: $0) }
            ?? home.appending(path: "Library/Logs/Homebrew")
    }

    /// The `api/internal` directory of the cache brew will use for the processes *we* spawn.
    nonisolated static func apiDirectory(environment: [String: String], home: URL) -> URL {
        cacheDirectory(environment: environment, home: home).appending(path: "api/internal")
    }

    /// When brew last ran a full cleanup: the mtime of the `.cleaned` marker (cleanup.rb:254).
    /// Both the periodic install-time clean and an explicit no-args `brew cleanup` touch it
    /// (cleanup.rb:427), so our own Clean Up refreshes this too. nil — never cleaned.
    func cleanedDate() -> Date? {
        let marker = Self.cacheDirectory(
            environment: effectiveEnvironment,
            home: URL.homeDirectory).appending(path: ".cleaned")
        return try? marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// brew 6 answers everything from one payload per arch tag (`packages.<tag>.jws.json`,
    /// api/internal.rb:30-31). The suffix match skips the `.payload`/`.payload.index` siblings,
    /// which brew rewrites on parse, not on refresh.
    nonisolated static func newestMetadataDate(in directory: URL) -> Date? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("packages.")
                && $0.lastPathComponent.hasSuffix(".jws.json") }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    // MARK: - Read helpers

    /// Per kind, each side nil on failure: the two lists are independent brew commands, and a
    /// crashing one must not discard the other's fresh answer — observed live when a brew
    /// master regression raised `uninitialized constant Cask::CaskLoader` from `list --cask`
    /// while `list --formula` was fine, which froze every formula's Installed state.
    func listInstalled() async -> (formulae: [Package.ID: InstalledInfo]?,
                                   casks: [Package.ID: InstalledInfo]?) {
        async let formulaOutput = capture(.listFormulae)
        async let caskOutput = capture(.listCasks)
        let formulae = (try? await formulaOutput).map { Self.parseListVersions($0, kind: .formula) }
        let casks = (try? await caskOutput).map { Self.parseListVersions($0, kind: .cask) }
        return (formulae, casks)
    }

    func outdated() async throws -> [Package.ID: OutdatedInfo] {
        try Self.parseOutdated(Data(await capture(.outdated).utf8))
    }

    func servicesList() async throws -> [String: ServiceStatus] {
        try Self.parseServicesList(Data(await capture(.servicesList).utf8))
    }

    // MARK: - Parsers

    /// `brew list --versions` prints `name v1 [v2 ...]` per line — in **readdir order**, not
    /// sorted: `cmd/list.rb` prints `d.subdirs` and `Pathname#subdirs` is a bare
    /// `children.select(&:directory?)` (`extend/pathname.rb`), while brew sorts where it cares
    /// (`Utils::Path.formula_installed_prefixes` ends `.sort_by(&:basename)`). Every consumer
    /// here reads `versions.last` as the live keg and `dropLast()` as the old ones, so the
    /// order is established once, at the only parse site. Measured on a 10-rack machine before
    /// this sort: 4 racks inverted, so the pane showed the superseded version, the receipt
    /// sweep read the wrong `INSTALL_RECEIPT.json`, and the uninstall dialog named the kegs
    /// backwards.
    ///
    /// ponytail: `.numeric` is a string sort, not brew's `PkgVersion` — it matches the opt keg
    /// on every real rack here, but a `HEAD-<sha>` keg sorts last whatever is linked. The exact
    /// answer is a `readlink` of `opt/<name>` per package, which is a filesystem walk to fix a
    /// comparator.
    static func parseListVersions(_ output: String, kind: PackageKind) -> [Package.ID: InstalledInfo] {
        var result: [Package.ID: InstalledInfo] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let name = fields.first, fields.count > 1 else { continue }
            let id = Package.packageID(kind: kind, name: shortName(String(name)))
            let versions = fields.dropFirst().map(String.init)
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            result[id] = InstalledInfo(versions: versions)
        }
        return result
    }

    /// `brew services list --json` → `[{name, status, user, file, exit_code}]`. Keyed by short
    /// name (services report keg names). A status string this build has never heard of becomes
    /// `.other` rather than a decode failure — brew has grown statuses before.
    static func parseServicesList(_ data: Data) throws -> [String: ServiceStatus] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode([ServiceEntry].self, from: jsonArray(in: data))

        var result: [String: ServiceStatus] = [:]
        for entry in entries {
            result[shortName(entry.name)] = ServiceStatus(
                health: entry.status.flatMap(ServiceHealth.init(rawValue:)) ?? .other,
                exitCode: entry.exitCode)
        }
        return result
    }

    private struct ServiceEntry: Decodable {
        let name: String
        let status: String?
        let exitCode: Int?
    }

    /// `brew outdated --json=v2` → `{"formulae": [...], "casks": [...]}`.
    static func parseOutdated(_ data: Data) throws -> [Package.ID: OutdatedInfo] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(OutdatedPayload.self, from: jsonObject(in: data))

        var result: [Package.ID: OutdatedInfo] = [:]
        for entry in payload.formulae ?? [] {
            result[Package.packageID(kind: .formula, name: shortName(entry.name))] = entry.info
        }
        for entry in payload.casks ?? [] {
            result[Package.packageID(kind: .cask, name: shortName(entry.name))] = entry.info
        }
        return result
    }

    /// `brew outdated` reports formulae by tap-qualified name; overlay keys use the keg name.
    /// `nonisolated` because the `@concurrent` receipt sweep normalizes `full_name`s with it.
    nonisolated static func shortName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// stdout and stderr share one stream, so a stray `Warning:` line can bracket the JSON.
    /// Shared with `DoctorReport.parse`, which had a hand-copy of the same trim —
    /// `nonisolated` because that decoder is.
    nonisolated static func jsonObject(in data: Data) -> Data {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start < end else { return data }
        return data[start...end]
    }

    /// Same trim for payloads whose top level is an array (`brew services list --json`).
    private static func jsonArray(in data: Data) -> Data {
        guard let start = data.firstIndex(of: UInt8(ascii: "[")),
              let end = data.lastIndex(of: UInt8(ascii: "]")),
              start < end else { return data }
        return data[start...end]
    }

    private struct OutdatedPayload: Decodable {
        struct Entry: Decodable {
            let name: String
            let installedVersions: [String]?
            let currentVersion: String?
            let pinned: Bool?

            var info: OutdatedInfo {
                OutdatedInfo(installed: installedVersions ?? [],
                             current: currentVersion ?? "",
                             pinned: pinned ?? false)
            }
        }

        let formulae: [Entry]?
        let casks: [Entry]?
    }

    // MARK: - Askpass helper

    /// Cask `pkg` artifacts call sudo, which has no TTY here; with `SUDO_ASKPASS` set brew passes
    /// `-A` and sudo asks through this script instead.
    static func askpassPath() -> String? {
        let directory = CatalogStore.supportDirectory
        let url = directory.appending(path: "askpass.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != askpassScript {
                try Data(askpassScript.utf8).write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    /// Mirrors the system auth prompt's grammar: app icon, why access is needed, what happens
    /// to the password, and a verb ("Allow") instead of OK. The AppleScript sits inside
    /// single-quoted sh, so an icon path containing a single quote falls back to no icon.
    private static var askpassScript: String {
        var icon = ""
        if let icns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")?.path,
           !icns.contains("'") {
            icon = " with icon POSIX file \"\(icns)\""
        }
        return """
            #!/bin/sh
            /usr/bin/osascript \\
              -e 'display dialog "Brewery is trying to modify software that requires administrator privileges.\\n\\nEnter your password to allow this. It goes directly to macOS and is never seen or stored by Brewery." default answer "" with hidden answer with title "Brewery"\(icon) buttons {"Cancel", "Allow"} default button "Allow" cancel button "Cancel"' \\
              -e 'text returned of result'

            """
    }
}

/// Accumulator for `capture`; a class so the `@Sendable` line callback can append into it.
private final class LineBuffer {
    var lines: [String] = []
}

/// Serializes signal delivery to the child: `interrupt()` is illegal before launch, pointless
/// after exit, and arrives from whichever thread cancelled the task.
private nonisolated final class SignalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    /// Call once the process is launched; delivers a signal that arrived too early.
    func arm(_ process: Process) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            process.interrupt()
            return
        }
        self.process = process
        lock.unlock()
    }

    /// SIGINT, not SIGTERM: brew traps Interrupt, cleans up and exits 130.
    func interrupt() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        running?.interrupt()
    }

    func disarm() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}
