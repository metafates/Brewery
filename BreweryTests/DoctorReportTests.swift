//
//  DoctorReportTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

@Suite("DoctorReport parsing")
struct DoctorReportTests {

    @Test("the full shape: tier, findings with affects, links and remediation commands")
    func fullDecode() {
        let json = """
        {
          "tier": 2,
          "findings": [
            {
              "text": "Warning: Broken symlinks were found. Remove them with `brew cleanup`:",
              "tier": 2,
              "affects": [],
              "links": [],
              "remediation": { "commands": ["brew cleanup"], "text": null }
            },
            {
              "text": "Warning: Some installed formulae are deprecated or disabled.",
              "tier": 1,
              "affects": ["python@3.10", "user/tap/gadget"],
              "links": ["https://docs.brew.sh/Deprecation"],
              "remediation": { "commands": [], "text": "Consider uninstalling them." }
            }
          ]
        }
        """
        let report = DoctorReport.parse(json)
        #expect(report?.tier == .number(2))
        #expect(report?.findings.count == 2)
        #expect(report?.findings[0].remediation?.commands == ["brew cleanup"])
        #expect(report?.findings[1].affects == ["python@3.10", "user/tap/gadget"])
        #expect(report?.findings[1].links == ["https://docs.brew.sh/Deprecation"])
        #expect(report?.findings[1].remediation?.text == "Consider uninstalling them.")
    }

    @Test("tier arrives as a string too — Ruby symbols serialize as labels")
    func tierAsString() {
        let json = """
        { "tier": "unsupported", "findings": [ { "text": "t", "tier": "unsupported" } ] }
        """
        let report = DoctorReport.parse(json)
        #expect(report?.tier == .label("unsupported"))
        #expect(report?.findings.first?.tier == .label("unsupported"))
    }

    @Test("a clean run is an empty findings array — the positive state's trigger")
    func cleanRun() {
        let report = DoctorReport.parse(#"{ "tier": 1, "findings": [] }"#)
        #expect(report != nil)
        #expect(report?.findings.isEmpty == true)
    }

    @Test("absent remediation, affects and links are tolerated")
    func sparseFinding() throws {
        let report = DoctorReport.parse(#"{ "tier": 1, "findings": [ { "text": "bare" } ] }"#)
        let finding = try #require(report?.findings.first)
        #expect(finding.text == "bare")
        #expect(finding.remediation == nil)
        #expect(finding.affects == nil)
    }

    @Test("JSON bracketed by stray prose lines is recovered; garbage is not")
    func trimming() {
        let noisy = """
        Warning: some stderr leaked here
        { "tier": 1, "findings": [] }
        trailing noise
        """
        #expect(DoctorReport.parse(noisy) != nil)
        #expect(DoctorReport.parse("Your system is ready to brew.") == nil)
        #expect(DoctorReport.parse("") == nil)
    }

    @Test("compact and pretty-printed forms both parse")
    func formats() {
        #expect(DoctorReport.parse(#"{"tier":1,"findings":[{"text":"x"}]}"#) != nil)
        let pretty = """
        {
          "tier": 1,
          "findings": [
            {
              "text": "x"
            }
          ]
        }
        """
        #expect(DoctorReport.parse(pretty) != nil)
    }
}

@Suite("Remedy classification")
struct RemedyTests {

    @Test("brew link with exactly one clean name goes native; anything else stays a chip")
    func link() {
        #expect(Remedy.classify("brew link mysql") == .link(formula: "mysql"))
        #expect(Remedy.classify("brew link lld@19") == .link(formula: "lld@19"))
        #expect(Remedy.classify("brew link mysql --force") == .chip(command: "brew link mysql --force"))
        #expect(Remedy.classify("brew link --overwrite mysql") == .chip(command: "brew link --overwrite mysql"))
        #expect(Remedy.classify("brew link a b") == .chip(command: "brew link a b"))
        #expect(Remedy.classify("brew link <formula>") == .chip(command: "brew link <formula>"))
    }

    @Test("bare cleanup goes native; any widening flag stays a chip")
    func cleanup() {
        #expect(Remedy.classify("brew cleanup") == .cleanup)
        #expect(Remedy.classify("brew cleanup -s") == .chip(command: "brew cleanup -s"))
        #expect(Remedy.classify("brew cleanup wget") == .chip(command: "brew cleanup wget"))
    }

    @Test("untap accepts one or many owner/repo taps, nothing else")
    func untap() {
        #expect(Remedy.classify("brew untap homebrew/core") == .untap(taps: ["homebrew/core"]))
        #expect(Remedy.classify("brew untap a/b c/d") == .untap(taps: ["a/b", "c/d"]))
        #expect(Remedy.classify("brew untap --force a/b") == .chip(command: "brew untap --force a/b"))
        #expect(Remedy.classify("brew untap notatap") == .chip(command: "brew untap notatap"))
    }

    @Test("install/upgrade tolerate only --cask; names shorten tap qualification")
    func packages() {
        #expect(Remedy.classify("brew install git") == .packages(names: ["git"], isCask: false))
        #expect(Remedy.classify("brew install --cask foo") == .packages(names: ["foo"], isCask: true))
        #expect(Remedy.classify("brew upgrade foo bar") == .packages(names: ["foo", "bar"], isCask: false))
        #expect(Remedy.classify("brew install user/tap/gum") == .packages(names: ["gum"], isCask: false))
        #expect(Remedy.classify("brew install --force foo") == .chip(command: "brew install --force foo"))
        // The linux gcc check's shape: reinstall is not install — never simplified.
        #expect(Remedy.classify("brew reinstall --cask --force megacmd") == .chip(command: "brew reinstall --cask --force megacmd"))
    }

    @Test("shell, sudo, git and redirects never go native",
          arguments: ["sudo rm -rf /Library/Developer",
                      "git -C \"/opt/homebrew\" stash -u && git clean -d -f",
                      "echo 'export PATH' >> ~/.zshrc",
                      "sudo xcodebuild -license",
                      "xcode-select --install"])
    func shell(command: String) {
        #expect(Remedy.classify(command) == .chip(command: command))
    }
}
