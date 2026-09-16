import SwiftUI

/// Says what a refresh found.
///
/// A refresh that lands new posts at the bottom of a long thread is invisible
/// to a reader sitting higher up, and one that finds nothing looks like the
/// gesture failed. This says which it was, and offers to go there.
struct RefreshToast: View {
    /// Why the refresh did not happen, when it did not. A failure is not
    /// "nothing new": the reader asked and did not get an answer.
    var failure: String?
    let newPostCount: Int
    /// How many of those answer something the reader wrote. Called out
    /// separately because it is the only part most readers came back for.
    var replyToOwnCount: Int = 0
    /// Called when the reader taps the toast, if there is anywhere to go.
    var onOpen: (() -> Void)?

    var body: some View {
        Group {
            if newPostCount > 0, failure == nil, let onOpen {
                Button(action: onOpen) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
        .accessibilityIdentifier("refresh-toast")
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconStyle)

            if let failure {
                Text(failure)
                    .font(.subheadline)
                    .lineLimit(2)
            } else if newPostCount > 0 {
                Text("\(newPostCount) new posts", bundle: .module)
                    .font(.subheadline.weight(.medium))

                if replyToOwnCount > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.secondary)
                    Text("\(replyToOwnCount) replies to you", bundle: .module)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            } else {
                Text("No new posts", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasNews: Bool { newPostCount > 0 }

    private var iconStyle: AnyShapeStyle {
        if failure != nil { return AnyShapeStyle(.orange) }
        return hasNews ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }

    private var icon: String {
        if failure != nil { return "exclamationmark.triangle.fill" }
        if replyToOwnCount > 0 { return "arrowshape.turn.up.left.circle.fill" }
        return newPostCount > 0 ? "arrow.down.circle.fill" : "checkmark.circle"
    }
}
