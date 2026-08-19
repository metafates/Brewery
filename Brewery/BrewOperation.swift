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
        lines.append(Self.stripANSI(line))
        if lines.count > Self.lineLimit {
            lines.removeFirst(lines.count - Self.lineLimit)
        }
    }

    /// A user's `brew.env` can force `HOMEBREW_COLOR=1`, in which case brew writes CSI escapes
    /// into a pipe that has no terminal to interpret them. Normalized once at ingest: the log
    /// view re-renders per appended line, and re-stripping every visible line there made a
    /// chatty upgrade pay the regex hundreds of times per frame.
    private nonisolated static let ansiEscape = #/\x1B\[[0-9;?]*[\x20-\x2F]*[\x40-\x7E]/#

    nonisolated static func stripANSI(_ line: String) -> String {
        line.replacing(ansiEscape, with: "")
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
    /// One vocabulary for every surface that names a state — the popover row, the log
    /// window's subtitle, and the pane's log header. "Queued" pairs with the popover's own
    /// "Remove from queue"; the pane used to say "Queued"/"Finished" while the popover said
    /// "Waiting"/"Completed" for the same states.
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running…"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
