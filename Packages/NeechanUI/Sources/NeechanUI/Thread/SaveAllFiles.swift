import NeechanCore
import SwiftUI

extension View {
    /// Asks before saving every file in the thread, then shows how it goes.
    ///
    /// - Parameter savesToFolder: whether files go to a folder the reader
    ///   chose rather than to Photos, for the question to say so.
    func saveAllFiles(
        model: ThreadViewModel,
        isConfirming: Binding<Bool>,
        savesToFolder: Bool
    ) -> some View {
        modifier(SaveAllFiles(model: model, isConfirming: isConfirming, savesToFolder: savesToFolder))
    }
}

/// Saving every file in a thread: a question first, since a long thread holds
/// hundreds, and then the same capsule, tap and alert the gallery uses.
///
/// A modifier of its own so the thread's body, already at the edge of what the
/// type checker will solve, does not carry five more.
private struct SaveAllFiles: ViewModifier {
    let model: ThreadViewModel
    @Binding var isConfirming: Bool
    let savesToFolder: Bool

    func body(content: Content) -> some View {
        let transfers = model.fileTransfers
        let count = model.snapshot.galleryItems.count
        content
            .confirmationDialog(
                Text("Save all \(count) files?", bundle: .module),
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button {
                    model.saveAllFiles()
                } label: {
                    Text("Save", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("Cancel", bundle: .module)
                }
            } message: {
                if savesToFolder {
                    Text("Files go to the folder chosen in Settings.", bundle: .module)
                } else {
                    Text("Files go to your photo library.", bundle: .module)
                }
            }
            .overlay(alignment: .bottom) {
                if let transfer = transfers.transfer {
                    TransferCapsule(transfer: transfer, batch: transfers.batch) {
                        transfers.cancelTransfer()
                    }
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: transfers.transfer)
            // The tick clears itself once it has been on screen long enough to read.
            .task(id: transfers.transfer?.isFinished) {
                guard transfers.transfer?.isFinished == true else { return }
                await transfers.clearFinishedTransfer()
            }
            .sensoryFeedback(trigger: transfers.lastVideoSave) { _, outcome in
                SaveHaptic.feedback(for: outcome)
            }
            // Only failures interrupt: a save that worked says so in the capsule.
            .alert(item: Binding(
                get: { transfers.saveResult },
                set: { transfers.saveResult = $0 }
            )) { result in
                Alert(
                    title: Text("Could not save", bundle: .module),
                    message: Text(result.message),
                    dismissButton: .default(Text("OK", bundle: .module))
                )
            }
    }
}
