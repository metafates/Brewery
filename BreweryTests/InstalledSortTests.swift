//
//  InstalledSortTests.swift
//  BreweryTests
//
//  v11 — Installed's sort orders: the comparators (newest/largest first, missing data last,
//  name as tiebreak) and the receipt `time` that feeds Date Installed.
//

import Foundation
import Testing
@testable import Brewery

struct InstalledSortTests {
    private func package(_ name: String) -> Package {
        Package(kind: .formula, name: name, displayName: nil, desc: nil,
                homepage: nil, version: "1", deprecated: false, disabled: false)
    }

    @Test("date installed: newest first, receipt-less kegs last, names break ties")
    func byInstallDate() {
        let (old, new, undated) = (package("old"), package("new"), package("undated"))
        let dates = ["formula:old": Date(timeIntervalSince1970: 1_000),
                     "formula:new": Date(timeIntervalSince1970: 2_000)]
        let sorted = [old, undated, new].sorted { ContentView.byInstallDate($0, $1, dates: dates) }
        #expect(sorted.map(\.name) == ["new", "old", "undated"])

        // Equal dates fall back to the canonical name order.
        let tied = ["formula:old": Date(timeIntervalSince1970: 5), "formula:new": Date(timeIntervalSince1970: 5)]
        #expect([old, new].sorted { ContentView.byInstallDate($0, $1, dates: tied) }.map(\.name) == ["new", "old"])
    }

    @Test("size: largest first, unmeasured last, names break ties")
    func bySize() {
        let (big, small, unknown) = (package("big"), package("small"), package("unknown"))
        let sizes: [Package.ID: Int64] = ["formula:big": 500, "formula:small": 3]
        let sorted = [small, unknown, big].sorted { ContentView.bySize($0, $1, sizes: sizes) }
        #expect(sorted.map(\.name) == ["big", "small", "unknown"])

        let tied: [Package.ID: Int64] = ["formula:big": 7, "formula:small": 7]
        #expect([small, big].sorted { ContentView.bySize($0, $1, sizes: tied) }.map(\.name) == ["big", "small"])
    }

    @Test("the receipt's time becomes installedAt; an absent time stays nil")
    func receiptTime() {
        let dated = Receipts.parse(Data(#"{"installed_on_request": true, "time": 1786359404}"#.utf8))
        #expect(dated.installedAt == Date(timeIntervalSince1970: 1_786_359_404))

        let undated = Receipts.parse(Data(#"{"installed_on_request": true}"#.utf8))
        #expect(undated.installedAt == nil)
    }
}
