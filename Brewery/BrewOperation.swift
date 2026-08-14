//
//  BrewOperation.swift
//  Brewery
//

import Foundation
import Observation

/// One brew invocation as the UI sees it: what was asked, how it is going, and the live log.
@Observable
final class BrewOperation: Identifiable {
    enum State: Equatable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
    }

    /// Older lines are dropped past this; a long `brew upgrade` can emit tens of thousands.
    static let lineLimit = 2000

    let id = UUID()
    let command: BrewCommand
    let title: String
    let targetID: Package.ID?
    var state: State = .queued
    /// v9 — true from the moment the operation finishes until the refresh it triggered has
    /// landed. In that window the overlays are still pre-mutation, so a card that dropped its
    /// busy state on `state` alone flashed the stale answer — "Install", a beat after
    /// installing — until the probes caught up.
    var awaitingRefresh = false
    private(set) var lines: [String] = []

    init(command: BrewCommand, title: String, targetID: Package.ID?) {
        self.command = command
        self.title = title
        self.targetID = targetID
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.lineLimit {
            lines.removeFirst(lines.count - Self.lineLimit)
        }
    }

    var isFinished: Bool {
        switch state {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }

    var symbolName: String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }
}

extension BrewOperation.State {
    /// One vocabulary for the popover row's caption and the log window's subtitle.
    var label: String {
        switch self {
        case .queued: "Waiting"
        case .running: "Running…"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
