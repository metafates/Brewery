//
//  OperationLogWindow.swift
//  Brewery
//

import SwiftUI

/// One operation's log in an auxiliary window — dedicated to a single experience, resizable,
/// live beside the app (HIG *Windows*: an auxiliary window "presents a specific task…
/// dedicated to one experience"). Reading a stream is not "a small amount of information",
/// which is where the popover's fixed 380-point frame stopped qualifying (HIG *Popovers*:
/// avoid making a popover too big); the popover keeps the glanceable queue, this keeps the
/// reading. The title bar carries what a header row would have: the operation as title, its
/// state as subtitle, Cancel in the toolbar (HIG *Progress indicators*: when it's feasible,
/// let people halt processing).
struct OperationLogWindow: View {
    @Environment(AppModel.self) private var model

    let operationID: BrewOperation.ID?

    var body: some View {
        if let operation = model.operations.first(where: { $0.id == operationID }) {
            OperationLogView(operation: operation)
                .padding(12)
                .frame(minWidth: 480, minHeight: 320)
                .navigationTitle(operation.title)
                .navigationSubtitle(operation.state.label)
                .toolbar {
                    if !operation.isFinished {
                        Button("Cancel") { model.cancel(operation) }
                            .help("Cancels the running operation")
                    }
                }
        } else {
            // Only reachable when a queued operation was removed after its window opened:
            // the session list otherwise keeps every operation, and restoration is off.
            ContentUnavailableView {
                Label("No Operation", systemImage: "list.bullet.rectangle")
            } description: {
                Text("This operation was cleared from the list.")
            }
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle("Log")
        }
    }
}
