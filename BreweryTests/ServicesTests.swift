//
//  ServicesTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

@Suite("Services")
struct ServicesTests {

    // MARK: - parseServicesList

    @Test("all seven statuses, nulls, and unknown strings decode")
    func statuses() throws {
        let json = """
        [
          {"name": "redis", "status": "started", "user": "u", "file": "/x", "exit_code": 0},
          {"name": "postgresql@17", "status": "stopped", "user": null, "file": "/x", "exit_code": 0},
          {"name": "ollama", "status": "none", "user": null, "file": "/x", "exit_code": null},
          {"name": "certbot", "status": "scheduled", "user": "u", "file": "/x", "exit_code": 0},
          {"name": "atuin", "status": "error", "user": "u", "file": "/x", "exit_code": 1},
          {"name": "mystery", "status": "unknown", "user": null, "file": "/x", "exit_code": null},
          {"name": "odd", "status": "other", "user": null, "file": "/x", "exit_code": null},
          {"name": "future", "status": "hyperspeed", "user": null, "file": "/x", "exit_code": null}
        ]
        """
        let statuses = try BrewClient.parseServicesList(Data(json.utf8))

        #expect(statuses.count == 8)
        #expect(statuses["redis"]?.health == .started)
        #expect(statuses["postgresql@17"]?.health == .stopped)
        #expect(statuses["ollama"]?.health == ServiceHealth.none)
        #expect(statuses["certbot"]?.health == .scheduled)
        #expect(statuses["atuin"] == ServiceStatus(health: .error, exitCode: 1))
        #expect(statuses["mystery"]?.health == .unknown)
        // A status string brew invents later must not fail the parse.
        #expect(statuses["future"]?.health == .other)
    }

    @Test("empty list, tap-qualified names, and a stray warning line")
    func edges() throws {
        #expect(try BrewClient.parseServicesList(Data("[]".utf8)).isEmpty)

        // Names normalize like every other overlay key, and stderr noise around the JSON is cut.
        let noisy = """
        Warning: something
        [{"name": "acme/tap/widgetd", "status": "started", "user": "u", "file": "/x", "exit_code": 0}]
        """
        let statuses = try BrewClient.parseServicesList(Data(noisy.utf8))
        #expect(statuses["widgetd"]?.health == .started)
        #expect(statuses["acme/tap/widgetd"] == nil)
    }

    @Test("toggle semantics: which healths read as loaded")
    func loaded() {
        #expect(ServiceHealth.started.isLoaded)
        #expect(ServiceHealth.scheduled.isLoaded)
        #expect(ServiceHealth.error.isLoaded)
        #expect(ServiceHealth.stopped.isLoaded)
        #expect(ServiceHealth.none.isLoaded == false)
        #expect(ServiceHealth.unknown.isLoaded == false)
        #expect(ServiceHealth.other.isLoaded == false)
    }

    // MARK: - Catalog service block

    @Test("service block decodes: array run, keep_alive object, log path")
    func decodeService() throws {
        let json = """
        [{"name": "redis", "desc": "d", "homepage": null,
          "versions": {"stable": "8.0"},
          "service": {"run": ["$HOMEBREW_PREFIX/opt/redis/bin/redis-server", "$HOMEBREW_PREFIX/etc/redis.conf"],
                      "run_type": "immediate", "keep_alive": {"always": true},
                      "working_dir": "$HOMEBREW_PREFIX/var",
                      "log_path": "$HOMEBREW_PREFIX/var/log/redis.log"}},
         {"name": "wget", "desc": "d", "homepage": null, "versions": {"stable": "1.0"}}]
        """
        let packages = try CatalogStore.decodeFormulae(Data(json.utf8))

        let redis = try #require(packages.first?.service)
        #expect(redis.run.count == 2)
        #expect(redis.runType == "immediate")
        #expect(redis.keepAlive)
        #expect(redis.logPath == "$HOMEBREW_PREFIX/var/log/redis.log")
        #expect(redis.scheduleLabel == "Runs continuously · restarts if it stops")

        // No service block → nil, and the entry still decodes.
        #expect(packages.last?.service == nil)
    }

    @Test("string-form run, require_root, sockets, interval and cron labels")
    func decodeVariants() throws {
        let json = """
        [{"name": "dnsmasq", "desc": null, "homepage": null, "versions": {"stable": "2.9"},
          "service": {"run": "$HOMEBREW_PREFIX/sbin/dnsmasq", "require_root": true,
                      "sockets": "tcp://127.0.0.1:6379"}},
         {"name": "certbot", "desc": null, "homepage": null, "versions": {"stable": "4.0"},
          "service": {"run": ["x"], "run_type": "interval", "interval": 300}},
         {"name": "logrotate", "desc": null, "homepage": null, "versions": {"stable": "3.0"},
          "service": {"run": ["x"], "run_type": "cron", "cron": "0 * * * *"}}]
        """
        let packages = try CatalogStore.decodeFormulae(Data(json.utf8))

        let dnsmasq = try #require(packages.first { $0.name == "dnsmasq" }?.service)
        #expect(dnsmasq.run == ["$HOMEBREW_PREFIX/sbin/dnsmasq"])
        #expect(dnsmasq.requireRoot)
        #expect(dnsmasq.ports == ["127.0.0.1:6379"])

        let certbot = try #require(packages.first { $0.name == "certbot" }?.service)
        #expect(certbot.scheduleLabel == "Every 5 minutes")

        let logrotate = try #require(packages.first { $0.name == "logrotate" }?.service)
        #expect(logrotate.scheduleLabel == "Scheduled: 0 * * * *")
    }

    @Test("prefix substitution feeds both caveats and service strings")
    func prefixSubstitution() {
        let prefix = URL(filePath: "/opt/homebrew", directoryHint: .isDirectory)
        #expect(Package.substitutingPrefix("$HOMEBREW_PREFIX/var/log/redis.log", prefix: prefix)
                == "/opt/homebrew/var/log/redis.log")
        #expect(Package.substitutingPrefix("no placeholder", prefix: prefix) == "no placeholder")
        #expect(Package.substitutingPrefix("$HOMEBREW_PREFIX/x", prefix: nil) == "$HOMEBREW_PREFIX/x")
    }
}
