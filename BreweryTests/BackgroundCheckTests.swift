//
//  BackgroundCheckTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

struct BackgroundCheckTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A tick yields to an active queue or a user refresh — and only to those.
    @Test func gateYieldsToActivity() {
        #expect(AppModel.shouldBackgroundCheck(queueActive: false, refreshing: false,
                                               last: nil, now: Self.epoch))
        #expect(!AppModel.shouldBackgroundCheck(queueActive: true, refreshing: false,
                                                last: nil, now: Self.epoch))
        #expect(!AppModel.shouldBackgroundCheck(queueActive: false, refreshing: true,
                                                last: nil, now: Self.epoch))
        #expect(!AppModel.shouldBackgroundCheck(queueActive: true, refreshing: true,
                                                last: nil, now: Self.epoch))
    }

    /// The wake trigger's gate. It shares this function, so a lid-open inside the window must
    /// read as not-due: brew's own 450 s staleness window would otherwise let every lid-open
    /// spend a `brew update` plus a full re-probe.
    @Test func intervalCoalescesWakes() {
        let last = Self.epoch
        func due(after seconds: TimeInterval) -> Bool {
            AppModel.shouldBackgroundCheck(queueActive: false, refreshing: false,
                                           last: last, now: last.addingTimeInterval(seconds))
        }
        #expect(!due(after: 0))
        #expect(!due(after: 600))      // eight minutes: stale to brew, not to the cadence
        #expect(!due(after: 6 * 3600 - 1))
        #expect(due(after: 6 * 3600))
        #expect(due(after: 24 * 3600))
    }

    /// A clock moved backwards reads as due — the alternative is a check that never runs again.
    @Test func backwardsClockIsDue() {
        #expect(AppModel.shouldBackgroundCheck(queueActive: false, refreshing: false,
                                               last: Self.epoch,
                                               now: Self.epoch.addingTimeInterval(-3600)))
    }

    /// The tripwire against a dev-time short cadence shipping: prototyping the loop means
    /// temporarily shrinking this interval, and this test is what makes "temporarily" true.
    @Test func intervalIsSixHours() {
        #expect(AppModel.backgroundCheckInterval == .seconds(21_600))
    }
}
