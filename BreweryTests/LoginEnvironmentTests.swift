//
//  LoginEnvironmentTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

struct LoginEnvironmentTests {
    private func data(_ records: [String], noise: String = "") -> Data {
        Data(noise.utf8) + Data([0]) + records.map { Data($0.utf8) + Data([0]) }.reduce(Data(), +)
    }

    @Test func parseDiscardsNoiseBeforeSentinel() {
        let parsed = LoginEnvironment.parse(data(["PATH=/opt/homebrew/bin"],
                                                 noise: "Welcome to fish!\nFAKE=greeting"))
        #expect(parsed == ["PATH": "/opt/homebrew/bin"])
    }

    @Test func parseWithoutSentinelIsEmpty() {
        #expect(LoginEnvironment.parse(Data("PATH=/usr/bin".utf8)).isEmpty)
        #expect(LoginEnvironment.parse(Data()).isEmpty)
    }

    @Test func parseSplitsOnFirstEqualsOnly() {
        let parsed = LoginEnvironment.parse(data(["LESS=-R --mouse=on"]))
        #expect(parsed["LESS"] == "-R --mouse=on")
    }

    @Test func parseKeepsNewlinesInsideValues() {
        let parsed = LoginEnvironment.parse(data(["MULTI=line one\nline two", "PATH=/bin"]))
        #expect(parsed["MULTI"] == "line one\nline two")
        #expect(parsed["PATH"] == "/bin")
    }

    @Test func parseDropsInvalidKeys() {
        let parsed = LoginEnvironment.parse(data(
            ["BAD KEY=x", "1NUM=x", "=x", "novalue", "_OK=y", "A1_b=z"]))
        #expect(parsed == ["_OK": "y", "A1_b": "z"])
    }

    @Test func overlayKeepsOnlyWhitelistedNames() {
        let overlay = LoginEnvironment.overlay(from: [
            "PATH": "/opt/homebrew/bin", "SHELL": "/opt/homebrew/bin/fish",
            "XDG_CONFIG_HOME": "/Users/u/.config", "XDG_CACHE_HOME": "/c", "XDG_DATA_HOME": "/d",
            "HOMEBREW_CACHE": "/cache", "HOMEBREW_NO_ANALYTICS": "1",
            "HOME": "/Users/u", "SSH_AUTH_SOCK": "/sock", "EDITOR": "nvim",
            "HOMEBREWX": "prefix trap",
            // brew's own proxy names (`env_config.rb`, carried by `build_environment.rb`'s
            // KEYS) — lowercase, and absent from `USED_BY_HOMEBREW_VARS`. Without them a
            // proxied Mac downloads the catalog and fails every install.
            "http_proxy": "http://p:8080", "no_proxy": "localhost",
            // brew declares lowercase only; the uppercase spelling is shell-emulator drift.
            "HTTP_PROXY": "http://nope:1",
        ])
        #expect(overlay == [
            "PATH": "/opt/homebrew/bin", "SHELL": "/opt/homebrew/bin/fish",
            "XDG_CONFIG_HOME": "/Users/u/.config", "XDG_CACHE_HOME": "/c", "XDG_DATA_HOME": "/d",
            "HOMEBREW_CACHE": "/cache", "HOMEBREW_NO_ANALYTICS": "1",
            "http_proxy": "http://p:8080", "no_proxy": "localhost",
        ])
    }

    /// Merge order is the contract: shell beats the GUI base, forced app vars beat the shell.
    @Test func mergePrecedence() {
        let merged = BrewClient.merged(
            base: ["PATH": "/usr/bin:/bin", "TERM": "dumb", "HOMEBREW_NO_ASK": "0"],
            overlay: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin",
                      "HOMEBREW_NO_ASK": "0", "HOMEBREW_CACHE": "/custom"],
            askpass: "/tmp/askpass.sh")
        #expect(merged["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(merged["TERM"] == "dumb")
        #expect(merged["HOMEBREW_CACHE"] == "/custom")
        #expect(merged["HOMEBREW_NO_ASK"] == "1")
        #expect(merged["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(merged["SUDO_ASKPASS"] == "/tmp/askpass.sh")
    }

    @Test func mergeWithoutAskpassSetsNoSudoVar() {
        let merged = BrewClient.merged(base: [:], overlay: [:], askpass: nil)
        #expect(merged["SUDO_ASKPASS"] == nil)
    }

    /// The deadline has to actually fire. It used to be unreachable: the surviving task-group
    /// child parks in `await reader.value`, which ignores the awaiting task's cancellation, so
    /// `cancelAll()` could not unwind the group's implicit await-all and everything after it
    /// was dead code. A shell that never exits then wedged `capture()` forever — and with it
    /// `shellEnvironment()`, every brew invocation, and `bootstrap()`. Both shapes are covered:
    /// a hanging shell, and a shell that exits leaving a descendant holding the pipe's write
    /// end (a dotfile that backgrounds a daemon), which SIGTERM alone does not unblock.
    @Test(arguments: ["sleep 60", "sleep 60 &"])
    func captureGivesUpOnAShellThatNeverCloses(tail: String) async throws {
        let script = URL.temporaryDirectory
            .appending(path: "brewery-stuck-shell-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nprintf '\\0'\n\(tail)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let started = ContinuousClock.now
        let overlay = await LoginEnvironment.capture(timeout: .milliseconds(200),
                                                     shell: script.path)
        // No PATH in the capture, so the overlay degrades to empty — the documented failure mode.
        #expect(overlay.isEmpty)
        #expect(started.duration(to: .now) < .seconds(5))
    }
}
