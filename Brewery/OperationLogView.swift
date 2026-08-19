//
//  OperationLogView.swift
//  Brewery
//

import SwiftUI

/// The live output of one brew invocation. `defaultScrollAnchor(.bottom)` both opens at the end and
/// keeps the newest line in view as the buffer grows, so a running operation tails itself.
struct OperationLogView: View {
    let operation: BrewOperation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if operation.lines.isEmpty {
                    Text("Waiting for output…")
                        .foregroundStyle(.tertiary)
                } else {
                    // Lines arrive ANSI-stripped from BrewOperation.append.
                    ForEach(operation.lines.enumerated(), id: \.offset) { _, line in
                        Text(line)
                            .foregroundStyle(Self.tint(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(8)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // Short output reads from the top, the way every log does; the two bottom anchors
        // keep the tail pinned once it overflows. One plain `.bottom` anchor also *aligned*
        // undersized content to the bottom — invisible in the popover's old 160-point frame,
        // a void above three lines in a full-height window.
        .defaultScrollAnchor(.top, for: .alignment)
        .frame(minHeight: 80)
        .background(.background.secondary, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output of \(operation.title)")
    }

    /// brew already prefixes its diagnostics; nothing else in the stream is worth tinting.
    private static func tint(for line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Error:") { return .red }
        if trimmed.hasPrefix("Warning:") { return .orange }
        return .primary
    }
}
