//
//  MaintenanceCopyTests.swift
//  BreweryTests
//

import Testing

@testable import Brewery

/// The storage card's one judgement call. Naming the dominant formula is what let the Old
/// Versions band go — it carried one useful fact (a single formula holding 400,6 MB of 640,3 MB)
/// behind nine rows that each said "1 old version". The threshold is the whole rule, so it is
/// the thing that gets a test: name a formula only when it really is most of the total, and
/// never describe a spread-out total as "mostly" anything.
struct StorageCaptionTests {
    private let mb: Int64 = 1_000_000

    @Test("a dominant formula is named with its size")
    func namesTheDominantFormula() {
        let caption = StorageSummaryBar.caption(total: 640 * mb,
                                                largest: (name: "container", bytes: 400 * mb))
        #expect(caption?.hasPrefix("Mostly old copies of container (") == true)
        // The promise that answers the question anyone hesitating over Clean Up is asking.
        #expect(caption?.hasSuffix("Nothing you use is removed.") == true)
    }

    @Test("a total spread across downloads and logs is described generically")
    func doesNotOverclaim() {
        // Exactly at the threshold still counts as dominant; a hair under does not.
        let atThreshold = StorageSummaryBar.caption(total: 1000 * mb,
                                                    largest: (name: "container", bytes: 400 * mb))
        #expect(atThreshold?.contains("container") == true)

        let below = StorageSummaryBar.caption(total: 1000 * mb,
                                              largest: (name: "container", bytes: 399 * mb))
        #expect(below?.contains("container") == false)
        #expect(below?.hasPrefix("Old copies of packages, finished downloads, and old logs.")
            == true)
    }

    @Test("nothing measured and nothing to reclaim carry no caption at all")
    func silentWhenThereIsNothingToSay() {
        // The headline already says "Nothing to clean up"; a sentence under it would repeat it.
        #expect(StorageSummaryBar.caption(total: 0, largest: nil) == nil)
        #expect(StorageSummaryBar.caption(total: nil, largest: nil) == nil)
        // Measured bytes with no multi-keg formula behind them: the generic line, not a crash.
        #expect(StorageSummaryBar.caption(total: 500 * mb, largest: nil)?.contains("old logs")
            == true)
    }
}
