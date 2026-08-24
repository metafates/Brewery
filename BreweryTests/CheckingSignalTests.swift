//
//  CheckingSignalTests.swift
//  BreweryTests
//

import Testing
@testable import Brewery

/// The one loading rule's signal: `isChecking` composes every source of state work, so the
/// toolbar glyph and the empty-slot capsules cannot miss one (the veil era's bug: five flags,
/// one veil, four invisible kinds of work).
struct CheckingSignalTests {
    @Test func quietWhenNothingRuns() {
        #expect(!AppModel.checking(refreshing: false, updatingMetadata: false,
                                   loadingCatalog: false, stateRefreshes: 0))
    }

    @Test func eachSourceAloneRaisesTheSignal() {
        #expect(AppModel.checking(refreshing: true, updatingMetadata: false,
                                  loadingCatalog: false, stateRefreshes: 0))
        #expect(AppModel.checking(refreshing: false, updatingMetadata: true,
                                  loadingCatalog: false, stateRefreshes: 0))
        #expect(AppModel.checking(refreshing: false, updatingMetadata: false,
                                  loadingCatalog: true, stateRefreshes: 0))
        #expect(AppModel.checking(refreshing: false, updatingMetadata: false,
                                  loadingCatalog: false, stateRefreshes: 1))
    }

    /// Overlapping probe passes (a ⌘R overtaking a post-mutation reconcile) keep the signal
    /// up until the last one lands — the reason it is a counter, not a Bool.
    @Test func overlappingProbePassesCountAsOne() {
        #expect(AppModel.checking(refreshing: false, updatingMetadata: false,
                                  loadingCatalog: false, stateRefreshes: 2))
    }
}
