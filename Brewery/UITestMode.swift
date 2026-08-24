//
//  UITestMode.swift
//  Brewery
//
//  Created by vzbarashchenko on 23.08.2026.
//

import Foundation

/// The deterministic UI-test harness's one activation point. Inert in production: every accessor
/// answers off a lazy static that stays nil unless the launch environment carries the payload.
///
/// The harness fakes exactly two process boundaries — the brew subprocess and the network — so
/// every layer of the app's own code (queue, `Process` exec and streaming, parsers, reconcile,
/// catalog decode and cache) runs for real under UI tests, and an error case is a fixture file,
/// not test-only code. The runner only *names* the fixture root (a path in the environment) and
/// ships the fixture bytes in a second variable; this process creates every directory and writes
/// every byte, script included — a runner-written file may be unreadable or unexecutable by the
/// app, and guessing at that OS policy costs more than deleting the question.
nonisolated enum UITestMode {
    /// Absolute path of the fixture root the test chose. Passed as a plain environment variable
    /// so `XDG_CONFIG_HOME`/`HOMEBREW_CACHE`/`HOMEBREW_LOGS` siblings under the same root reach
    /// brew children through the ordinary environment merge — the login-shell overlay is empty
    /// under the harness, so what the test sets is what the app and its children see.
    static let rootKey = "BREWERY_UITEST_ROOT"
    /// The fixture tree in transit: `base64(zlib(JSON(Payload)))`. Presence is activation —
    /// there is no separate flag to forget or misorder.
    static let payloadKey = "BREWERY_UITEST_PAYLOAD"

    /// What travels: relative paths under the root → bytes, plus whether the fake brew exists
    /// at all (`installBrew: false` is the brew-missing scenario).
    struct Payload: Codable, Equatable {
        var files: [String: Data]
        var installBrew: Bool

        enum PayloadError: Error { case notBase64 }

        func encoded() throws -> String {
            let json = try JSONEncoder().encode(self)
            let compressed = try (json as NSData).compressed(using: .zlib)
            return (compressed as Data).base64EncodedString()
        }

        static func decoded(from encoded: String) throws -> Self {
            guard let compressed = Data(base64Encoded: encoded) else { throw PayloadError.notBase64 }
            let json = try (compressed as NSData).decompressed(using: .zlib)
            return try JSONDecoder().decode(Self.self, from: json as Data)
        }
    }

    struct Installation {
        let root: URL
        let brewPath: URL?
    }

    /// Decoded and installed on first access from whichever seam fires first (`static let` is
    /// once-and-thread-safe, which covers the nonisolated callers too). A malformed payload is a
    /// test-authoring bug and dies loudly — silently falling through to the real machine is the
    /// one unacceptable failure mode.
    static let installation: Installation? = {
        let environment = ProcessInfo.processInfo.environment
        guard let encoded = environment[payloadKey] else { return nil }
        guard let rootPath = environment[rootKey] else {
            fatalError("UITestMode: \(payloadKey) is set but \(rootKey) is missing")
        }
        do {
            let payload = try Payload.decoded(from: encoded)
            return try install(payload, at: URL(filePath: rootPath, directoryHint: .isDirectory))
        } catch {
            fatalError("UITestMode: fixture install failed: \(error)")
        }
    }()

    static var active: Bool { installation != nil }
    static var brewPath: URL? { installation?.brewPath }
    static var supportDirectory: URL? {
        installation?.root.appending(path: "support", directoryHint: .isDirectory)
    }
    static var httpFixturesDirectory: URL? {
        installation?.root.appending(path: "http", directoryHint: .isDirectory)
    }

    private static func install(_ payload: Payload, at root: URL) throws -> Installation {
        let manager = FileManager.default
        // Every directory a seam or env sibling points into exists up front, so an empty
        // scenario degrades (missing fixture, empty dir) rather than erroring on a path.
        for directory in ["support", "http", "brew", "brew-state", "logs",
                          "config/homebrew", "cache/api/internal"] {
            try manager.createDirectory(at: root.appending(path: directory, directoryHint: .isDirectory),
                                        withIntermediateDirectories: true)
        }
        for (relativePath, contents) in payload.files {
            let destination = root.appending(path: relativePath, directoryHint: .notDirectory)
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try contents.write(to: destination)
        }
        // A fresh-mtime metadata payload: the freshness rule stats `HOMEBREW_CACHE`'s
        // `packages.<tag>.jws.json` mtimes, and with none the model would inject a surprise
        // "Updating Homebrew" ahead of every mutation a test drives.
        try Data().write(to: root.appending(path: "cache/api/internal/packages.uitest.jws.json",
                                            directoryHint: .notDirectory))

        var brewPath: URL?
        if payload.installBrew {
            // prefix/bin/brew makes the client's derived prefix and repository point into the
            // root, where the pin, receipt and tap scans all find empty directories and degrade
            // exactly as they do on a machine with nothing installed.
            let brew = root.appending(path: "prefix/bin/brew", directoryHint: .notDirectory)
            try manager.createDirectory(at: brew.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try Data(fakeBrewScript.utf8).write(to: brew)
            // The askpass helper's exact treatment: written by this process, owner-executable.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew.path)
            brewPath = brew
        }
        return Installation(root: root, brewPath: brewPath)
    }

    /// The fake brew: a fixture lookup table, not a switch over subcommands. The key is the argv
    /// joined by `_` (`list_--formula_--versions`); answers come from `<key>.stdout` / `.stderr`
    /// / `.exitcode` files, defaulting to empty output and exit 0 when at least one exists. A
    /// successful run copies `<key>.apply/` into the state overlay, which later lookups consult
    /// first — how "install succeeded" changes what the next probes answer, through the app's
    /// real reconcile path. A missing fixture exits 64 naming the path it wanted, so a test
    /// failure states which command the scenario forgot rather than timing out mutely.
    static let fakeBrewScript = """
    #!/bin/bash
    # fake-brew — deterministic stand-in for Homebrew. Generated by Brewery/UITestMode.swift.
    set -u
    root="${BREWERY_UITEST_ROOT:?}"
    fixtures="${root}/brew"
    state="${root}/brew-state"
    key="$(IFS=_; echo "$*")"

    pick() {  # the state overlay wins over the fixture dir
        if [[ -f "${state}/${key}${1}" ]]; then echo "${state}/${key}${1}"
        else echo "${fixtures}/${key}${1}"; fi
    }
    stdout_file="$(pick .stdout)"; stderr_file="$(pick .stderr)"; exit_file="$(pick .exitcode)"

    if [[ ! -f "${stdout_file}" && ! -f "${stderr_file}" && ! -f "${exit_file}" ]]; then
        echo "fake-brew: no fixture for 'brew $*'" >&2
        echo "fake-brew: looked for ${stdout_file}" >&2
        exit 64
    fi

    # A held answer: `<key>.delay` (seconds) sleeps before any output, so a test can pin what
    # the UI does *while* a command runs. Deliberately after the missing-fixture check — a
    # .delay alone is not an answer.
    delay_file="$(pick .delay)"
    [[ -f "${delay_file}" ]] && sleep "$(cat "${delay_file}")"

    [[ -f "${stdout_file}" ]] && cat "${stdout_file}"
    [[ -f "${stderr_file}" ]] && cat "${stderr_file}" >&2
    status=0
    [[ -f "${exit_file}" ]] && status="$(cat "${exit_file}")"

    # A successful mutation replaces later answers: the .apply/ tree lands in the overlay.
    if [[ "${status}" -eq 0 && -d "${fixtures}/${key}.apply" ]]; then
        mkdir -p "${state}"
        cp -R "${fixtures}/${key}.apply/." "${state}/"
    fi
    exit "${status}"
    """
}
