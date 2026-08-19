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
        ])
        #expect(overlay == [
            "PATH": "/opt/homebrew/bin", "SHELL": "/opt/homebrew/bin/fish",
            "XDG_CONFIG_HOME": "/Users/u/.config", "XDG_CACHE_HOME": "/c", "XDG_DATA_HOME": "/d",
            "HOMEBREW_CACHE": "/cache", "HOMEBREW_NO_ANALYTICS": "1",
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
}
