//
//  FreshnessCaptionTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// The "Last checked" caption's bucketing: minute granularity that turns over
/// exactly at the unit boundary, and never a future phrasing when the tick predates the stat.
@MainActor
struct FreshnessCaptionTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func underAMinuteIsJustNow() {
        #expect(ContentView.lastCheckedCaption(checked: now, now: now)
            == "Last checked just now")
        #expect(ContentView.lastCheckedCaption(checked: now.addingTimeInterval(-59), now: now)
            == "Last checked just now")
    }

    @Test func theMinuteBoundaryFlipsTheUnit() {
        #expect(ContentView.lastCheckedCaption(checked: now.addingTimeInterval(-60), now: now)
            == "Last checked 1 minute ago")
        #expect(ContentView.lastCheckedCaption(checked: now.addingTimeInterval(-7200), now: now)
            == "Last checked 2 hours ago")
    }

    @Test func aTickBehindTheStatNeverPhrasesTheFuture() {
        // .everyMinute's ticks were minute-aligned, so the first could predate a fresh mtime;
        // clock skew can do the same. "In 30 seconds" must be unrepresentable.
        #expect(ContentView.lastCheckedCaption(checked: now.addingTimeInterval(30), now: now)
            == "Last checked just now")
    }
}
