import SwiftUI

/// What a save or a share is doing, over the media it is doing it to.
///
/// A capsule rather than a panel: the reader can keep paging through the
/// gallery while a long clip comes down, which a blocking overlay would stop.
struct TransferCapsule: View {
    let transfer: GalleryViewModel.Transfer
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
            label
                .font(.footnote.weight(.medium))
                .monospacedDigit()

            if !transfer.isFinished {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel", bundle: .module))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, transfer.isFinished ? 14 : 2)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .accessibilityIdentifier("transfer-capsule")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch transfer.stage {
        case .downloading:
            // Determinate where the server said how big the file is, and a
            // plain spinner where it did not: a bar that cannot move is worse
            // than no bar.
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .converting:
            if let fraction = transfer.fraction, fraction > 0 {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .saving:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        }
    }

    private var label: Text {
        switch transfer.stage {
        case .downloading:
            if let fraction = transfer.fraction {
                Text("Saving \(Int(fraction * 100))%", bundle: .module)
            } else {
                Text("Saving", bundle: .module)
            }
        case .converting:
            if let fraction = transfer.fraction, fraction > 0 {
                Text("Converting \(Int(fraction * 100))%", bundle: .module)
            } else {
                Text("Converting", bundle: .module)
            }
        case .saving:
            Text("Saving", bundle: .module)
        case .finished:
            Text("Saved", bundle: .module)
        }
    }
}
