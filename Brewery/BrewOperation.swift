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
    /// True from the moment the operation finishes until the refresh it triggered has
    /// landed. In that window the overlays are still pre-mutation, so a card that dropped its
    /// busy state on `state` alone flashed the stale answer — "Install", a beat after
    /// installing — until the probes caught up.
    var awaitingRefresh = false
    /// The refresh generation current when this operation finished. The hold releases only
    /// when a refresh that *started after* the completion publishes — the operation's own
    /// fire-and-forget refresh can be superseded and bail before publishing, and dropping
    /// the hold then would flash the pre-mutation overlays (the blink bug, resurrected).
    var awaitingRefreshSince = 0
    private(set) var lines: [String] = []

    /// What brew last said it was doing — its own `==> ` headline, prefix stripped. brew
    /// narrates itself through `ohai`, and `ohai_title` truncates *only* when stdout is a TTY
    /// (`utils/output.rb`); this app pipes, so headlines arrive whole and there is nothing to
    /// classify. Unrecognised output leaves it alone, so a reworded brew degrades to the state
    /// word rather than to a wrong caption.
    private(set) var stage: String?

    /// brew's own last `Error:` sentence, prefix stripped — the same prefix the log view
    /// already trusts for its red tint, and the one `AppModel.execute` synthesizes for a
    /// missing brew or a thrown error, so those get a readable failure for free.
    private(set) var errorSummary: String?

    init(command: BrewCommand, title: String, targetID: Package.ID?) {
        self.command = command
        self.title = title
        self.targetID = targetID
    }

    /// Narration is computed **here**, at the one ingest chokepoint, and stored — never
    /// derived in a view body. `lines` is observed, so every appended line already invalidates
    /// every reader; a stored property rides that for free, while a computed property scanning
    /// `lines` would reinstate exactly the quadratic cost the ANSI strip was moved here to fix.
    func append(_ line: String) {
        let clean = Self.stripANSI(line)
        lines.append(clean)
        if lines.count > Self.lineLimit {
            lines.removeFirst(lines.count - Self.lineLimit)
        }
        if let headline = Self.headline(in: clean) { stage = headline }
        if let sentence = Self.errorSentence(in: clean) { errorSummary = sentence }
    }

    /// brew's `ohai` headline, or nil for anything else — including, deliberately, a headline
    /// whose subject is a bare URL. `==> Downloading https://ghcr.io/v2/…` alternates with
    /// `==> Fetching ffmpeg` several times a second during a pour; the fetch line is the one
    /// that names what is happening, and the URL would flicker over it while saying less.
    nonisolated static func headline(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("==> ") else { return nil }
        let subject = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        // The scheme sits after the verb — the line is `==> Downloading <url>` — so the test is
        // "does this headline name a URL at all", not "does it start with one".
        guard !subject.isEmpty, !subject.contains("://") else { return nil }
        return subject
    }

    /// brew prefixes its own diagnostics, so the sentence needs no parsing — only the prefix
    /// dropped. Zero classification is the point: Cork's equivalent guesses with unanchored
    /// regexes and mis-attributes lines to the wrong stage.
    nonisolated static func errorSentence(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Error:") else { return nil }
        let sentence = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        return sentence.isEmpty ? nil : sentence
    }

    /// What a surface says about this operation right now: brew's own words when it has said
    /// something, the state word otherwise. `State.label`'s one-vocabulary contract, extended
    /// rather than patched into one caller — the popover row, the log window's subtitle and
    /// the pane's log header all read this, and drifting apart is what the contract forbids.
    ///
    /// `.cancelled` deliberately keeps its state word: `BrewError.cancelled` is caught without
    /// writing a log line, so the last thing brew said before the interrupt is not the outcome.
    var statusLine: String {
        switch state {
        case .running: stage ?? state.label
        case .failed: errorSummary ?? state.label
        default: state.label
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
