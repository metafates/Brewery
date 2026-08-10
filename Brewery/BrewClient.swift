//
//  BrewClient.swift
//  Brewery
//

import Foundation
import Observation

enum BrewError: Error, Equatable {
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
    }

    /// Apple silicon prefix first, then Intel. Re-run on ⌘R so installing brew needs no relaunch.
    func discover() {
        let existing = Self.candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
        path = existing.map { URL(filePath: $0) }
    }

    // MARK: - Invocation

    /// Core exec. Streams every stdout and stderr line to `onLine`, returns brew's exit code.
    func run(_ command: BrewCommand,
             onLine: @MainActor @Sendable @escaping (String) -> Void) async throws -> Int32 {
        guard let executable = path else { throw BrewError.notFound }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        process.environment = Self.environment(for: command)
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
                        await Self.forward(errors.fileHandleForReading, to: onLine)
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

    private static func environment(for command: BrewCommand) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_ASK"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if command.isMutating, let askpass = askpassPath() {
            environment["SUDO_ASKPASS"] = askpass
        }
        return environment
    }

    // MARK: - Read helpers

    func listInstalled() async throws -> [Package.ID: InstalledInfo] {
        async let formulaOutput = capture(.listFormulae)
        async let caskOutput = capture(.listCasks)
        let (formulae, casks) = try await (formulaOutput, caskOutput)

        var result = Self.parseListVersions(formulae, kind: .formula)
        for (id, info) in Self.parseListVersions(casks, kind: .cask) {
            result[id] = info
        }
        return result
    }

    func outdated() async throws -> [Package.ID: OutdatedInfo] {
        try Self.parseOutdated(Data(await capture(.outdated).utf8))
    }

    // MARK: - Parsers

    /// `brew list --versions` prints `name v1 [v2 ...]` per line.
    static func parseListVersions(_ output: String, kind: PackageKind) -> [Package.ID: InstalledInfo] {
        var result: [Package.ID: InstalledInfo] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let name = fields.first, fields.count > 1 else { continue }
            let id = Package.packageID(kind: kind, name: shortName(String(name)))
            result[id] = InstalledInfo(versions: fields.dropFirst().map(String.init))
        }
        return result
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
    private static func jsonObject(in data: Data) -> Data {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
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

    private static let askpassScript = """
        #!/bin/sh
        /usr/bin/osascript \\
          -e 'display dialog "Brewery needs administrator access to continue." default answer "" with hidden answer with title "Brewery"' \\
          -e 'text returned of result'

        """
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
