//
//  BackgroundCheckTests.swift
//  BreweryTests
//

import Testing
@testable import Brewery

struct BackgroundCheckTests {
    /// A tick yields to an active queue or a user refresh — and only to those.
    @Test func gateYieldsToActivity() {
        #expect(AppModel.shouldBackgroundCheck(queueActive: false, refreshing: false))
        #expect(!AppModel.shouldBackgroundCheck(queueActive: true, refreshing: false))
        #expect(!AppModel.shouldBackgroundCheck(queueActive: false, refreshing: true))
        #expect(!AppModel.shouldBackgroundCheck(queueActive: true, refreshing: true))
    }

    /// The tripwire against a dev-time short cadence shipping: prototyping the loop means
    /// temporarily shrinking this interval, and this test is what makes "temporarily" true.
    @Test func intervalIsSixHours() {
        #expect(AppModel.backgroundCheckInterval == .seconds(21_600))
    }
}
