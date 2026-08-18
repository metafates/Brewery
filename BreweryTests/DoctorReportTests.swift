//
//  DoctorReportTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

@Suite("DoctorReport parsing (v19)")
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
    func sparseFinding() {
        let report = DoctorReport.parse(#"{ "tier": 1, "findings": [ { "text": "bare" } ] }"#)
        #expect(report?.findings.first?.text == "bare")
        #expect(report?.findings.first?.remediation == nil)
        #expect(report?.findings.first?.affects == nil)
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
