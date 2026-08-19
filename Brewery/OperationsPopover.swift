//
//  OperationsPopover.swift
//  Brewery
//

import SwiftUI

/// The Safari-downloads pattern: everything this session did, newest first, glanceable and
/// manageable here — read in a window. The logs used to unfold inline, which outgrew the
/// surface (HIG *Popovers*: "use a popover to expose a small amount of information"; "avoid
/// making a popover too big"): a monospace stream in a fixed 380-point frame clipped lines
/// and buried the queue it shared the popover with.
struct OperationsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Operations")
                    .font(.headline)
                Spacer()
                // Safari's Downloads grammar: Clear drops the finished, keeps the live. Absent
                // when there is nothing to clear. (Operations still awaiting their refresh
                // survive it — see clearFinishedOperations.)
                if model.operations.contains(where: { $0.isFinished && !$0.awaitingRefresh }) {
                    Button("Clear") { model.clearFinishedOperations() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Remove finished operations from the list")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.operations.reversed()) { operation in
                        row(operation)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 380)
    }

    private func row(_ operation: BrewOperation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: operation.symbolName)
                .foregroundStyle(tint(for: operation.state))
                // The "Running…" caption below already says this without moving.
                .symbolEffect(.rotate, options: .repeating,
                              isActive: operation.state == .running && !reduceMotion)

            VStack(alignment: .leading, spacing: 1) {
                Text(operation.title)
                    .lineLimit(1)
                Text(operation.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            switch operation.state {
            case .running:
                // The popover's one quiet style (Clear's): a lone bordered control in a row
                // of borderless ones read as drift, not emphasis.
                Button("Cancel") { model.cancel(operation) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            case .queued:
                Button {
                    model.remove(operation)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove from queue")
                .accessibilityLabel("Remove from queue")
            default:
                EmptyView()
            }

            Button {
                openWindow(id: "operation-log", value: operation.id)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Open the log in its own window")
            .accessibilityLabel("Show Log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tint(for state: BrewOperation.State) -> Color {
        switch state {
        case .queued, .cancelled: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }
}
