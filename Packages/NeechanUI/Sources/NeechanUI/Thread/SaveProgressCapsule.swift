import SwiftUI

extension View {
    /// Says how far a save has got, without taking the thread away.
    ///
    /// A capsule rather than a dimmed modal like the reply form's: sending a
    /// post takes seconds, while saving a thread with its files runs for
    /// minutes, and a reader held out of the thread for all of it would be
    /// waiting on a download they could have read through.
    ///
    /// One modifier, and non-generic on purpose. The chain this joins is at the
    /// edge of what the type checker will solve -- the report sheet tipped it
    /// over and had to be folded into a single entry as well.
    func saveProgress(
        _ progress: ThreadViewModel.SaveProgress?,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(SaveProgressCapsule(progress: progress, onCancel: onCancel))
    }
}

private struct SaveProgressCapsule: ViewModifier {
    let progress: ThreadViewModel.SaveProgress?
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let progress {
                capsule(progress)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func capsule(_ progress: ThreadViewModel.SaveProgress) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                label(progress)
                    .font(.subheadline)
                // Determinate once the file count is known. Before that the
                // JSON is still being written, which is quick, and a bar that
                // sat at zero for a moment reads better than one that spins.
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel", bundle: .module))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
        .accessibilityIdentifier("save-progress")
    }

    /// The total is zero only for the instant before the first count arrives,
    /// and "0 of 0" is a worse thing to show than the verb on its own.
    ///
    /// The bare verb is the catalogue's existing "Saving" rather than a new
    /// "Saving…": the two generate the same symbol, so adding the second is a
    /// build error.
    private func label(_ progress: ThreadViewModel.SaveProgress) -> Text {
        progress.filesTotal == 0
            ? Text("Saving", bundle: .module)
            : Text(
                "Saving files: \(progress.filesDone) of \(progress.filesTotal)",
                bundle: .module
            )
    }
}
