//
//  AttentionSummaryBar.swift
//  Brewery
//

import SwiftUI

/// v11 — the Attention scope's header: how many installed packages Homebrew has retired, and
/// what that means. The orphan bar's chrome, but **no action button, deliberately**: nothing
/// safe to enqueue exists — uninstalling is a non-goal — and a report is not a task. The
/// per-package specifics (why, since when, when it stops working, what replaces it) are the
/// detail pane's job, which the explainer points at.
struct AttentionSummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.installedPackages(scope: .attention).count
        if count > 0 {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    // The banner's warning colour, not the tint: this bar is the same fact.
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("^[\(count) packages](inflect: true) won't receive updates")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Homebrew has deprecated or disabled these. Each package's page says why, and what to use instead.")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }
            .contentBox()
            .accessibilityElement(children: .combine)
        }
    }
}
