import EditorKit
import SwiftUI

/// A move away from a photo whose edits aren't saved, waiting for the user to decide what becomes
/// of them: stepping to another photo, or taking the photo out of the album it is looked at in.
struct PendingLeave {
    /// The photo being left.
    let model: EditorModel
    /// Makes the move, once the edits are saved or given up.
    let proceed: () -> Void
}

extension View {
    /// Asks whether to save the edits of the photo being left, then makes the move; Cancel stays.
    func unsavedChangesPrompt(_ pending: Binding<PendingLeave?>) -> some View {
        confirmationDialog("Save the changes to this photo?", isPresented: Binding(get: { pending.wrappedValue != nil }, set: {
            if !$0 {
                pending.wrappedValue = nil
            }
        }), titleVisibility: .visible, presenting: pending.wrappedValue) { leave in
            Button("Save") {
                Task {
                    await leave.model.save()
                    // A save that failed says so in the editor: the photo stays, with its edits.
                    if !leave.model.hasUnsavedChanges {
                        leave.proceed()
                    }
                }
            }
            Button("Discard Changes", role: .destructive) { leave.proceed() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Moving to another photo discards the edits you haven't saved.")
        }
    }
}
