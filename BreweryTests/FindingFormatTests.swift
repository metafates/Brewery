//
//  FindingFormatTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// Fixtures copied verbatim from brew's diagnostic.rb shapes (its own
/// test/diagnostic_checks_spec.rb pins the texts).
struct FindingFormatTests {
    static let pathText = """
        /usr/bin occurs before /opt/homebrew/bin in your PATH.
        This means that system-provided programs will be used instead of those
        provided by Homebrew.

        The following tools exist at both paths:
          gem
          git
          ruby
        """

    static let tapsText = """
        The following taps are not trusted:
          charmbracelet/tap
          oven-sh/bun

        Homebrew is currently ignoring formulae, casks and commands from these taps because tap trust is required.
        """

    @Test func classification() {
        #expect(FindingFormat.classify(Self.pathText) == .pathShadowing)
        #expect(FindingFormat.classify(Self.tapsText) == .untrustedTaps)
        #expect(FindingFormat.classify("You have unlinked kegs in your Cellar.") == .generic)
        // The first line alone isn't enough for PATH — the tools sentinel must be present too.
        #expect(FindingFormat.classify("/usr/bin occurs before /opt/homebrew/bin in your PATH.")
                == .generic)
        // A reworded header stops matching; nothing downstream fires.
        #expect(FindingFormat.classify("Some taps are not trusted:\n  a/b") == .generic)
    }

    @Test func toolListShape() {
        #expect(FindingFormat.toolList(inCode: "gem\ngit\nruby") == ["gem", "git", "ruby"])
        #expect(FindingFormat.toolList(inCode: "python3\ngit-receive-pack\ngzexe")
                == ["python3", "git-receive-pack", "gzexe"])
        // Any line that isn't a bare name fails the whole block — degrade to chip.
        #expect(FindingFormat.toolList(inCode: "gem\n/usr/bin/git") == nil)
        #expect(FindingFormat.toolList(inCode: "gem\ntwo words") == nil)
        #expect(FindingFormat.toolList(inCode: "") == nil)
    }

    @Test func tapListShape() {
        #expect(FindingFormat.tapList(inCode: "charmbracelet/tap\noven-sh/bun")
                == ["charmbracelet/tap", "oven-sh/bun"])
        #expect(FindingFormat.tapList(inCode: "a/b/c") == nil)
        #expect(FindingFormat.tapList(inCode: "https://git.example/foo") == nil)
        #expect(FindingFormat.tapList(inCode: "justonename") == nil)
        #expect(FindingFormat.tapList(inCode: "") == nil)
    }

    @Test func soleURLShape() {
        #expect(FindingFormat.soleURL(inCode: "https://docs.brew.sh/Tap-Trust")?.absoluteString
                == "https://docs.brew.sh/Tap-Trust")
        #expect(FindingFormat.soleURL(inCode: "https://a.example\nhttps://b.example") == nil)
        #expect(FindingFormat.soleURL(inCode: "brew doctor") == nil)
    }

    /// The PATH remediation duplicates its one-liner between `commands` and the prose; the
    /// commands array is the single chip source, so the prose's copy vanishes.
    @Test func remediationDedupesAgainstCommands() {
        let blocks = FindingFormat.remediationBlocks(
            text: """
                Consider setting your PATH so that
                /opt/homebrew/bin occurs before /usr/bin. Here is a one-liner:
                  fish_add_path /opt/homebrew/bin
                """,
            commands: ["fish_add_path /opt/homebrew/bin"],
            links: [])
        #expect(blocks == [.text("Consider setting your PATH so that\n/opt/homebrew/bin occurs before /usr/bin. Here is a one-liner:")])
    }

    /// The tap-trust remediation has no commands — its blank-line-free prose/command
    /// alternation must survive as alternating blocks, `brew trust` lines emerging as code.
    @Test func trustRemediationKeepsItsAlternation() {
        let blocks = FindingFormat.remediationBlocks(
            text: """
                Prefer trusting only the specific formulae, casks or commands you need.
                Trust installed formulae from these taps with:
                  brew trust --formula charmbracelet/tap/crush charmbracelet/tap/gum
                Untap them with:
                  brew untap charmbracelet/tap
                For more information, see:
                  https://docs.brew.sh/Tap-Trust
                """,
            commands: [],
            links: ["https://docs.brew.sh/Tap-Trust"])
        #expect(blocks == [
            .text("Prefer trusting only the specific formulae, casks or commands you need.\nTrust installed formulae from these taps with:"),
            .code("brew trust --formula charmbracelet/tap/crush charmbracelet/tap/gum"),
            .text("Untap them with:"),
            .code("brew untap charmbracelet/tap"),
            // The trailing "For more information, see:" + URL pair folded away: the finding's
            // links row is that URL's one home.
        ])
    }

    @Test func trailingURLStaysWithoutMatchingLink() {
        let blocks = FindingFormat.remediationBlocks(
            text: "For more information, see:\n  https://docs.brew.sh/Tap-Trust",
            commands: [],
            links: [])
        #expect(blocks == [.text("For more information, see:"),
                           .code("https://docs.brew.sh/Tap-Trust")])
    }

    @Test func subtitleFormatting() {
        #expect(FindingFormat.shadowsSubtitle(["gem"]) == "Shadowed command: gem")
        #expect(FindingFormat.shadowsSubtitle(["gem", "irb", "ruby"])
                == "Shadowed commands: gem, irb, ruby")
    }

    /// The whole-finding pipeline: blocks of the PATH text split prose from the tool list.
    @Test func pathFindingBlocks() {
        let blocks = CaveatFormat.blocks(of: Self.pathText)
        #expect(blocks == [
            .text("/usr/bin occurs before /opt/homebrew/bin in your PATH.\nThis means that system-provided programs will be used instead of those\nprovided by Homebrew."),
            .text("The following tools exist at both paths:"),
            .code("gem\ngit\nruby"),
        ])
    }
}

struct ShadowResolverTests {
    @Test func providerFromLinkDestination() {
        #expect(ShadowResolver.provider(ofLinkDestination: "../Cellar/ruby/3.4.1/bin/gem")?.name == "ruby")
        #expect(ShadowResolver.provider(ofLinkDestination: "../Cellar/ruby/3.4.1/bin/gem")?.kind == .formula)
        #expect(ShadowResolver.provider(ofLinkDestination: "/opt/homebrew/Cellar/python@3.12/3.12.4/bin/pip3")?.name == "python@3.12")
        #expect(ShadowResolver.provider(ofLinkDestination: "../Caskroom/some-cli/1.0/some")?.kind == .cask)
        #expect(ShadowResolver.provider(ofLinkDestination: "/usr/local/bin/other") == nil)
        // A trailing marker with nothing after it names no package.
        #expect(ShadowResolver.provider(ofLinkDestination: "../Cellar") == nil)
    }

    @Test func groupingPreservesOrderAndCollectsUnresolved() {
        let ids = ["gem": "formula:ruby", "ruby": "formula:ruby", "git": "formula:git"]
        let (groups, unresolved) = ShadowResolver.grouped(tools: ["gem", "git", "mystery", "ruby"]) {
            ids[$0]
        }
        #expect(groups.map(\.id) == ["formula:ruby", "formula:git"])
        #expect(groups.first?.tools == ["gem", "ruby"])
        #expect(unresolved == ["mystery"])
    }
}
