//
//  CaveatFormatTests.swift
//  BreweryTests
//

import SwiftUI
import Testing
@testable import Brewery

@Suite("Caveat formatting")
struct CaveatFormatTests {

    @Test("the python@3.10 shape: prose and indented runs alternate, indent stripped")
    func pythonShape() {
        let text = """
        Python is installed as
          /opt/homebrew/bin/python3.10

        You can install Python packages with
          pip3.10 install <package>
        They will install into the site-package directory
          /opt/homebrew/lib/python3.10/site-packages
        """
        #expect(CaveatFormat.blocks(of: text) == [
            .text("Python is installed as"),
            .code("/opt/homebrew/bin/python3.10"),
            .text("You can install Python packages with"),
            .code("pip3.10 install <package>"),   // verbatim — no markdown eats the <angle brackets>
            .text("They will install into the site-package directory"),
            .code("/opt/homebrew/lib/python3.10/site-packages"),
        ])
    }

    @Test("multi-line command runs stay one block; backticks in prose stay for the renderer")
    func grouping() {
        let text = """
        To restart `foo` run:
          brew services stop foo
          brew services start foo
        """
        #expect(CaveatFormat.blocks(of: text) == [
            .text("To restart `foo` run:"),
            .code("brew services stop foo\nbrew services start foo"),
        ])
    }

    @Test("attributed prose: code spans get the mono chip, bare URLs become links")
    func attributed() throws {
        let result = CaveatFormat.attributed("Run `tlmgr` first, see https://example.com/docs for details")

        func run(containing text: String) -> AttributedString.Runs.Run? {
            guard let range = result.range(of: text) else { return nil }
            return result.runs.first { $0.range.contains(range.lowerBound) }
        }

        let code = run(containing: "tlmgr")
        #expect(code?.font == .callout.monospaced())
        #expect(code?.backgroundColor != nil)

        #expect(run(containing: "https://example.com/docs")?.link?.host() == "example.com")

        // Prose stays un-chipped and un-linked. `#require` first: a nil run would satisfy
        // the two nil-checks while proving nothing.
        let prose = try #require(run(containing: "first"))
        #expect(prose.font == nil)
        #expect(prose.link == nil)
    }

    @Test("all-prose, all-code, tabs, and trailing blank lines")
    func edges() {
        #expect(CaveatFormat.blocks(of: "Just a sentence.") == [.text("Just a sentence.")])
        #expect(CaveatFormat.blocks(of: "\tmake install\n") == [.code("make install")])
        #expect(CaveatFormat.blocks(of: "A\nB\n\n\nC\n\n") == [.text("A\nB"), .text("C")])
        #expect(CaveatFormat.blocks(of: "") == [])
    }

    // MARK: - Install mentions

    private typealias Mention = CaveatFormat.InstallMention

    @Test("the pnpm shape: one command, one mention")
    func mentionBasic() {
        #expect(CaveatFormat.installMentions(in: "brew install node") == [Mention(name: "node", isCask: false)])
    }

    @Test("the buildkitd shape: multiple names per line, embedded labels and non-brew commands ignored")
    func mentionMultiple() {
        let code = """
        OCI worker mode:
        brew install nerdctl containerd rootlesskit slirp4netns
        rootlesskit buildkitd
        """
        #expect(CaveatFormat.installMentions(in: code) == [
            Mention(name: "nerdctl", isCask: false),
            Mention(name: "containerd", isCask: false),
            Mention(name: "rootlesskit", isCask: false),
            Mention(name: "slirp4netns", isCask: false),
        ])
    }

    @Test("the amazon-music shape: other brew verbs ignored, --cask honored, flags with values skipped")
    func mentionVerbsAndFlags() {
        let code = """
        brew uninstall --zap --cask amazon-music
        brew install --cask --appdir=/Applications amazon-music
        """
        #expect(CaveatFormat.installMentions(in: code) == [Mention(name: "amazon-music", isCask: true)])
        // --cask is position-independent; --HEAD never becomes a name.
        #expect(CaveatFormat.installMentions(in: "brew install foo --cask") == [Mention(name: "foo", isCask: true)])
        #expect(CaveatFormat.installMentions(in: "brew install --HEAD foo") == [Mention(name: "foo", isCask: false)])
    }

    @Test("the vorta shape: tap-qualified names keep only the short name")
    func mentionTapQualified() {
        #expect(CaveatFormat.installMentions(in: "brew install borgbackup/tap/borgbackup-fuse")
            == [Mention(name: "borgbackup-fuse", isCask: false)])
    }

    @Test("name charset: versioned and punctuated names survive, placeholders don't")
    func mentionCharset() {
        #expect(CaveatFormat.installMentions(in: "brew install lld@19 gtk+3 python-matplotlib") == [
            Mention(name: "lld@19", isCask: false),
            Mention(name: "gtk+3", isCask: false),
            Mention(name: "python-matplotlib", isCask: false),
        ])
        #expect(CaveatFormat.installMentions(in: "brew install <formula> \\") == [])
    }

    @Test("chains, prompts and sudo: defensive splitting")
    func mentionChains() {
        #expect(CaveatFormat.installMentions(in: "$ sudo brew install a && brew install b; echo done") == [
            Mention(name: "a", isCask: false),
            Mention(name: "b", isCask: false),
        ])
    }

    @Test("dedup within a block, order preserved; no mentions in unrelated code")
    func mentionDedup() {
        let code = """
        brew install node
        brew install node pnpm
        """
        #expect(CaveatFormat.installMentions(in: code) == [
            Mention(name: "node", isCask: false),
            Mention(name: "pnpm", isCask: false),
        ])
        #expect(CaveatFormat.installMentions(in: "make install\nbrew services restart foo") == [])
        #expect(CaveatFormat.installMentions(in: "") == [])
    }
}
