//
//  DoctorReport.swift
//  Brewery
//

import Foundation

/// v19 — `brew doctor --json`'s payload (cmd/doctor.rb:89-93, shape from
/// diagnostic/finding.rb:70-77): a support tier plus findings, each carrying its text, the
/// package names it affects, doc links, and a remediation whose `commands` are the
/// machine-readable fix. Decoding is deliberately tolerant — the flag is hidden and every
/// field but `text` is treated as optional — and `tier` is an int *or* a string ("unsupported").
nonisolated struct DoctorReport: Decodable, Equatable {
    struct Finding: Decodable, Equatable {
        let text: String
        let tier: TierValue?
        let affects: [String]?
        let links: [String]?
        let remediation: Remediation?
    }

    struct Remediation: Decodable, Equatable {
        let commands: [String]?
        let text: String?
    }

    /// Ruby emits the tier as an Integer or a Symbol (→ JSON string).
    enum TierValue: Decodable, Equatable {
        case number(Int)
        case label(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .label(try container.decode(String.self))
            }
        }
    }

    let tier: TierValue?
    let findings: [Finding]

    /// nil on anything that doesn't decode — the caller's raw-text fallback trigger. The
    /// bracket trim recovers JSON bracketed by stray prose lines (the outdated parser's rule).
    static func parse(_ text: String) -> DoctorReport? {
        let data = Data(text.utf8)
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start < end else { return nil }
        return try? JSONDecoder().decode(DoctorReport.self, from: data[start...end])
    }
}
