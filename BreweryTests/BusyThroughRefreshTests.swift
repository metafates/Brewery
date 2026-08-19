//
//  BusyThroughRefreshTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// The blink bug's regression test: a finished operation must keep its card busy until the
/// post-operation refresh lands. Between those two moments the overlays still answer for the
/// old world, and dropping busy on completion alone flashed "Install" right after installing.
@MainActor
struct BusyThroughRefreshTests {

    private let wget = Package(kind: .formula, name: "wget", displayName: nil, desc: nil,
                               homepage: nil, version: "1.25.0",
                               deprecated: false, disabled: false)

    @Test func finishedOperationHoldsItsCardUntilOverlaysRefresh() {
        let model = AppModel()
        let operation = BrewOperation(command: .install(name: "wget", cask: false),
                                      title: "Installing wget", targetID: wget.id)
        operation.state = .succeeded
        operation.awaitingRefresh = true
        model.operations.append(operation)

        #expect(model.status(for: wget) == .busy)

        operation.awaitingRefresh = false
        #expect(model.status(for: wget) == .notInstalled)
    }

    @Test func clearDropsTheFinishedButNeverTheLiveOrTheRefreshing() {
        let model = AppModel()
        let finished = BrewOperation(command: .update, title: "Updating Homebrew", targetID: nil)
        finished.state = .succeeded
        let refreshing = BrewOperation(command: .install(name: "wget", cask: false),
                                       title: "Installing wget", targetID: wget.id)
        refreshing.state = .succeeded
        refreshing.awaitingRefresh = true
        let running = BrewOperation(command: .upgradeAll, title: "Updating all packages", targetID: nil)
        running.state = .running
        model.operations = [finished, refreshing, running]

        model.clearFinishedOperations()

        #expect(model.operations.map(\.title) == ["Installing wget", "Updating all packages"])
    }

    @Test func finishedUpgradeAllHoldsEveryOutdatedCard() {
        let model = AppModel()
        model.outdated[wget.id] = OutdatedInfo(installed: ["1.24.0"], current: "1.25.0",
                                               pinned: false)
        let operation = BrewOperation(command: .upgradeAll,
                                      title: "Updating all packages", targetID: nil)
        operation.state = .succeeded
        operation.awaitingRefresh = true
        model.operations.append(operation)

        #expect(model.status(for: wget) == .busy)

        operation.awaitingRefresh = false
        #expect(model.status(for: wget) == .outdated(installed: "1.24.0", current: "1.25.0"))
    }
}

/// The superseded-refresh case: only a refresh that started *after* an operation finished may
/// release its hold — an older run's release would drop busy against pre-mutation overlays.
@MainActor
struct RefreshHoldReleaseTests {
    @Test func onlyOperationsStampedBeforeTheRunAreReleased() {
        let model = AppModel()
        let old = BrewOperation(command: .update, title: "old", targetID: nil)
        old.state = .succeeded
        old.awaitingRefresh = true
        old.awaitingRefreshSince = 1
        let fresh = BrewOperation(command: .update, title: "fresh", targetID: nil)
        fresh.state = .succeeded
        fresh.awaitingRefresh = true
        fresh.awaitingRefreshSince = 5
        model.operations = [old, fresh]

        model.releaseRefreshHolds(before: 3)

        #expect(old.awaitingRefresh == false)
        #expect(fresh.awaitingRefresh)
    }
}
