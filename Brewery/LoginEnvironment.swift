//
//  LoginEnvironment.swift
//  Brewery
//

import Foundation

/// The user's login-shell environment, captured once per launch and overlaid onto every
/// brew child. A Finder-launched app inherits launchd's environment, not the shell's, and brew
/// reads real configuration from the environment: the trust store and user `brew.env` resolve
/// through `XDG_CONFIG_HOME` (bin/brew:163-170, trust.rb:27-34), doctor's PATH checks judge
/// the launch PATH (diagnostic.rb:496-582 via `ORIGINAL_PATHS`), and remediation one-liners
/// pick their syntax from `SHELL` (utils/shell.rb:24-30). Without the overlay the app's brew
/// answered for a machine the user doesn't have: trusted taps read as untrusted (so brew
/// ignored their formulae), and doctor invented PATH findings about launchd's PATH.
nonisolated enum LoginEnvironment {
    /// The user-environment names brew itself consumes (bin/brew's `USED_BY_HOMEBREW_VARS`),
    /// minus the ones the app must own. Everything else the shell exports stays out: the
    /// overlay is terminal parity for brew, not a shell emulator.
    static let whitelistedNames: Set<String> = [
        "PATH", "SHELL", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
    ]

    /// The account's login shell (`getpwuid`), falling back to `$SHELL`, then zsh — the same
    /// resolution order Terminal uses, so the captured environment is the one a new tab gets.
    static func loginShellPath() -> String? {
        var candidates: [String] = []
        if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
            candidates.append(String(cString: shell))
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            candidates.append(shell)
        }
        candidates.append("/bin/zsh")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `env -0` output → dictionary. Everything before the first NUL is dotfile noise (the
    /// payload prints a NUL sentinel first, so greeting banners can't corrupt record one);
    /// records are NUL-delimited, so values containing newlines survive; each record splits on
    /// its first `=`; keys must look like environment names or the record is dropped.
    static func parse(_ data: Data) -> [String: String] {
        guard let sentinel = data.firstIndex(of: 0) else { return [:] }
        var result: [String: String] = [:]
        for record in data[data.index(after: sentinel)...].split(separator: 0) {
            guard let string = String(data: Data(record), encoding: .utf8),
                  let equals = string.firstIndex(of: "=") else { continue }
            let key = String(string[..<equals])
            guard isValidName(key) else { continue }
            result[key] = String(string[string.index(after: equals)...])
        }
        return result
    }

    /// The POSIX name rule; anything else is shell noise.
    private static func isValidName(_ key: String) -> Bool {
        key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
    }

    /// The whitelist: the exact names above plus every `HOMEBREW_`-prefixed variable.
    static func overlay(from environment: [String: String]) -> [String: String] {
        environment.filter { whitelistedNames.contains($0.key) || $0.key.hasPrefix("HOMEBREW_") }
    }

    /// Runs the login shell once and returns the whitelisted overlay. Any failure — no shell,
    /// launch error, timeout, unparseable output — returns empty, which merges as a no-op:
    /// capture failure merely loses the overlay. `@concurrent` so the spawn and
    /// the byte-by-byte pipe drain leave the caller's actor (the reader Task inherits this
    /// context) instead of running on the main thread.
    @concurrent static func capture(timeout: Duration = .seconds(3)) async -> [String: String] {
        guard let shell = loginShellPath() else { return [:] }

        let process = Process()
        process.executableURL = URL(filePath: shell)
        // `-l -c` as separate argv elements (fish rejects the combined spelling); absolute tool
        // paths so builtins never matter. The quoted \0 is the sentinel `parse` keys off.
        process.arguments = ["-l", "-c", "/usr/bin/printf '\\0'; /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let (exit, exitSignal) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exitSignal.finish() }
        do {
            try process.run()
        } catch {
            return [:]
        }

        // Drained concurrently for the same reason BrewClient.run does: a >64 KB environment
        // must not fill the pipe and deadlock the child against our wait.
        let handle = pipe.fileHandleForReading
        let reader = Task {
            var data = Data()
            do {
                for try await byte in handle.bytes { data.append(byte) }
            } catch {}
            return data
        }

        // Exit-then-EOF, raced against the deadline: a broken dotfile that hangs the shell (or
        // a login item holding the pipe open) costs the timeout once per launch, not a wedge.
        let data = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await _ in exit {}
                return await reader.value
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let data else {
            reader.cancel()
            process.terminate()
            // Plain Task, not detached: a delayed side effect needs no fresh isolation
            // domain, and this context is already nonisolated.
            Task {
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            return [:]
        }

        // A login shell always exports PATH; its absence means the shell died before the
        // payload ran, and half-captured noise must not become the app's idea of the terminal.
        let overlay = overlay(from: parse(data))
        return overlay["PATH"] == nil ? [:] : overlay
    }
}
