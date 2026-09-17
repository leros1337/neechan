import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One post in a thread.
///
/// Deliberately not `Equatable`, and deliberately not wrapped in `.equatable()`.
/// It looks like an easy win — the cell is mostly values, and comparing them
/// would let SwiftUI skip rebuilding a post that has not changed — but the
/// comparison would have to ignore the closures below, and skipping the update
/// then keeps the closures from the pass that built them. Those capture the
/// thread view, and writing its `@State` through a stale copy is dropped
/// silently: tapping a thumbnail stopped opening the gallery, and nothing said
/// so. What that optimisation was for is covered instead by `PostBodyCache`,
/// which makes a repeated render a dictionary lookup.
struct PostCellView: View {

    let post: Post
    let content: PostContent
    let backlinks: [Int]
    let isOwn: Bool
    let repliesToOwn: Bool
    let isDeleted: Bool
    let isNew: Bool
    let revealSpoilers: Bool
    /// Position of the post in the thread, counting the opening post as one.
    var indexInThread: Int?

    var onOpenReplies: () -> Void
    /// Opens the gallery at the tapped attachment.
    var onOpenAttachment: (NeechanAPI.Attachment) -> Void = { _ in }
    /// Opens the reply form quoting this post.
    /// Nil where the site takes no posts from this app; the action is then
    /// not offered rather than offered and refused.
    var onReply: (() -> Void)? = nil
    /// Hides posts by a rule made from this one.
    var onHide: (LocalHideRule) -> Void = { _ in }
    /// This post's own address on the site, for copying and sharing.
    var postURL: URL?

    @Environment(AppServices.self) private var services
    @Environment(\.neechanTheme) private var theme
    /// The post body's size at the reader's Dynamic Type setting, before their
    /// own text scale multiplies it.
    @ScaledMetric(relativeTo: .callout) private var bodyPointSize: CGFloat = 16
    @State private var isExpanded = false


    /// Posts longer than this are collapsed, with a control to open them.
    private var collapsedLineLimit: Int { services.settings.collapsePostLineLimit }

    var body: some View {
        // Rendered once. Building an `AttributedString` walks the whole post and
        // coalesces runs, and this used to happen twice per body: once to draw,
        // once inside the probe that measures whether the text was cut off.
        let rendered = attributedBody

        return VStack(alignment: .leading, spacing: 8) {
            PostHeaderView(
                post: post,
                indexInThread: indexInThread,
                isOwn: isOwn,
                isDeleted: isDeleted
            )

            if !post.files.isEmpty {
                AttachmentsRow(attachments: post.files, onSelect: onOpenAttachment)
            }

            if !content.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rendered)
                        .font(bodyFont)
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : collapsedLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .background { truncationProbe(rendered) }
                        // Named so the text scale can be checked by measuring
                        // the thing it is supposed to resize.
                        .accessibilityIdentifier("post-body-\(post.num)")

                    if isTruncated, !isExpanded {
                        expandButton
                    }
                }
            }

            if !backlinks.isEmpty {
                RepliesButton(count: backlinks.count, action: onOpenReplies)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cellBackground)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            // Own posts and replies to them get a border, the way Dashchan marks
            // them, so they are findable while scrolling fast.
            if isOwn || repliesToOwn {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isOwn ? Color.accentColor : Color.accentColor.opacity(0.4), lineWidth: 1.5)
            }
        }
        .opacity(isDeleted ? 0.55 : 1)
        .contextMenu {
            if let onReply {
                Button {
                    onReply()
                } label: {
                    Label {
                        Text("Reply to this post", bundle: .module)
                    } icon: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                }
            }
            Button {
                copyToPasteboard(content.plainText)
            } label: {
                Label {
                    Text("Copy text", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            Button {
                copyToPasteboard("\(post.num)")
            } label: {
                Label {
                    Text("Copy post number", bundle: .module)
                } icon: {
                    Image(systemName: "number")
                }
            }
            if !backlinks.isEmpty {
                Button(action: onOpenReplies) {
                    Label {
                        Text("Show replies", bundle: .module)
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                }
            }
            Section {
                Menu {
                    Button { onHide(.post(num: post.num)) } label: {
                        Text("This post", bundle: .module)
                    }
                    Button { onHide(.repliesTree(num: post.num)) } label: {
                        Text("This post and its replies", bundle: .module)
                    }
                    if !post.name.isEmpty {
                        Button { onHide(.name(post.name)) } label: {
                            Text("Posts by \(post.name)", bundle: .module)
                        }
                    }
                    if !content.plainText.isEmpty {
                        Button { onHide(.similar(to: content.plainText)) } label: {
                            Text("Posts like this one", bundle: .module)
                        }
                    }
                } label: {
                    Label {
                        Text("Hide", bundle: .module)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                }
            }
            if let postURL {
                Section {
                    LinkActionsMenu(url: postURL, title: "№\(post.num)")
                }
            }
        }
    }

    private var attributedBody: AttributedString {
        PostBodyCache.shared.body(
            for: content,
            board: post.board,
            options: .init(
                postNum: post.num,
                revealSpoilers: revealSpoilers,
                palette: .init(theme: theme)
            )
        )
    }

    /// The body font: Dynamic Type, multiplied by the reader's own text scale.
    private var bodyFont: Font {
        .system(size: bodyPointSize * services.settings.textScale)
    }

    private var cellBackground: some ShapeStyle {
        isNew ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.background.secondary)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.snappy) { isExpanded = true }
        } label: {
            Text("Show more", bundle: .module)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
    }

    /// Measures the body at its natural height against the clipped one.
    ///
    /// SwiftUI does not report whether a line limit truncated anything, so the
    /// same text is laid out twice: once as drawn, once unconstrained.
    @ViewBuilder
    private func truncationProbe(_ rendered: AttributedString) -> some View {
        // Mounted only for posts long enough that the limit could reach them,
        // and only while they are collapsed. A board is mostly one-line replies,
        // and laying each of those out a second time to discover it was never
        // going to be cut off is the most wasted work in the thread.
        if !isExpanded, couldTruncate {
            // Two height readings rather than two nested `GeometryReader`s: a
            // `GeometryReader` fills whatever it is offered and takes part in
            // layout, so a pair of them per post was shaping the thread as well
            // as measuring it. `onGeometryChange` only reports.
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    clippedHeight = height
                }
                .overlay {
                    Text(rendered)
                        .font(bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            naturalHeight = height
                        }
                }
        }
    }

    /// Whether this post is long enough to be worth measuring.
    private var couldTruncate: Bool {
        CollapsePolicy.mayTruncate(
            lineBreaks: content.lineBreakCount,
            characters: content.plainText.count,
            limit: collapsedLineLimit
        )
    }

    /// Height of the body as drawn, with the line limit applied.
    @State private var clippedHeight: CGFloat = 0
    /// Height the same body would take unconstrained.
    @State private var naturalHeight: CGFloat = 0

    /// Whether the line limit actually cut this post off.
    ///
    /// A point of slack, so rounding does not make a full post look clipped.
    private var isTruncated: Bool {
        couldTruncate && clippedHeight > 0 && naturalHeight > clippedHeight + 1
    }
}

/// Author, number and time, plus the badges that matter at a glance.
struct PostHeaderView: View {
    let post: Post
    /// Position in the thread, shown before the name so a reader can tell how
    /// far in a post sits without counting.
    var indexInThread: Int?
    let isOwn: Bool
    let isDeleted: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let indexInThread {
                Text(verbatim: "\(indexInThread)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Post \(indexInThread)", bundle: .module))
            }

            if let flag = post.icon?.flagEmoji {
                Text(verbatim: flag)
                    .font(.caption)
                    .accessibilityLabel(Text(post.icon?.title ?? flag))
            }

            Text(displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(post.tripcode.isEmpty ? Color.secondary : Color.accentColor)
                .lineLimit(1)

            // Boards with poster IDs give each poster a generated nickname in
            // their own colour, which is the only way to tell one from another.
            if let posterID = post.posterID {
                Text(posterID)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(posterIDColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if post.isOP {
                BadgeLabel(text: Text("OP", bundle: .module), tint: .accentColor)
            }
            if isOwn {
                // Named rather than implied: the border around an own post is
                // easy to miss in a thread that is mostly Аноним, and the only
                // posts marked here are the ones sent from this device.
                BadgeLabel(text: Text("(Me)", bundle: .module), tint: .accentColor)
            }
            if post.isSage {
                BadgeLabel(text: Text(verbatim: "SAGE"), tint: .secondary)
            }
            if post.isBanned {
                BadgeLabel(text: Text("Banned", bundle: .module), tint: .red)
            } else if post.isWarned {
                BadgeLabel(text: Text("Warned", bundle: .module), tint: .orange)
            }
            if isDeleted {
                BadgeLabel(text: Text("Deleted", bundle: .module), tint: .secondary)
            }

            Spacer(minLength: 0)

            Text(verbatim: "№\(post.num)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(post.postedAt, format: .dateTime.day().month().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// The colour the site gave this poster, or a neutral one when it gave none.
    private var posterIDColor: Color {
        guard let colour = post.posterIDColor else { return .secondary }
        return Color(
            .sRGB,
            red: Double(colour.red) / 255,
            green: Double(colour.green) / 255,
            blue: Double(colour.blue) / 255
        )
    }

    private var displayName: String {
        let name = post.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trip = post.tripcode.trimmingCharacters(in: .whitespacesAndNewlines)
        return [name, trip].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct BadgeLabel: View {
    let text: Text
    let tint: Color

    var body: some View {
        text
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: .capsule)
            .foregroundStyle(tint)
    }
}

/// How many posts replied to this one.
///
/// A row of raw `>>` numbers said nothing a reader could use and grew unusable
/// on a busy post. The count opens a window listing the replies in full.
private struct RepliesButton: View {
    let count: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("\(count) replies", bundle: .module)
            } icon: {
                Image(systemName: "arrowshape.turn.up.left.2")
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityHint(Text("Shows the replies to this post", bundle: .module))
    }
}

/// A post's attachments, side by side.
struct AttachmentsRow: View {
    let attachments: [NeechanAPI.Attachment]
    var onSelect: (NeechanAPI.Attachment) -> Void = { _ in }

    var body: some View {
        if attachments.count == 1, let only = attachments.first {
            Button { onSelect(only) } label: {
                ThumbnailView(attachment: only, side: 160)
            }
            .buttonStyle(.plain)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        Button { onSelect(attachment) } label: {
                            ThumbnailView(attachment: attachment, side: 110)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
