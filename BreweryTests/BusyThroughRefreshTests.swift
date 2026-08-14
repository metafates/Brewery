//
//  BusyThroughRefreshTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// v9 — the blink bug's regression test: a finished operation must keep its card busy until the
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
