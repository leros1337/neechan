import NeechanAPI
import NeechanCore
import NeechanSettings
import SwiftUI

/// A thread as a card: thumbnail, subject, a few lines of the opening post.
///
/// The thumbnail and the text are separate targets: tapping the picture opens
/// it, tapping anything else opens the thread.
struct ThreadCardView: View {
    let thread: ThreadSummary
    let board: Board?
    var onOpenThread: () -> Void
    var onOpenMedia: (NeechanAPI.Attachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let attachment = thread.opPost.files.first {
                    MediaTapTarget(
                        attachment: attachment,
                        side: 78,
                        count: thread.opPost.files.count,
                        action: onOpenMedia
                    )
                }
                Button(action: onOpenThread) {
                    VStack(alignment: .leading, spacing: 4) {
                        ThreadTitle(thread: thread)
                        ThreadPreviewText(post: thread.opPost, lineLimit: 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Button(action: onOpenThread) {
                ThreadFooter(thread: thread)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }
}

/// A thread as a single compact line.
struct ThreadRowView: View {
    let thread: ThreadSummary
    var onOpenThread: () -> Void
    var onOpenMedia: (NeechanAPI.Attachment) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let attachment = thread.opPost.files.first {
                MediaTapTarget(
                    attachment: attachment,
                    side: 44,
                    count: thread.opPost.files.count,
                    action: onOpenMedia
                )
            }
            Button(action: onOpenThread) {
                VStack(alignment: .leading, spacing: 3) {
                    ThreadTitle(thread: thread)
                    ThreadPreviewText(post: thread.opPost, lineLimit: 2)
                    ThreadFooter(thread: thread)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A thread as a grid tile dominated by its image.
///
/// The picture opens itself; the title and counts below open the thread.
struct ThreadGridCell: View {
    let thread: ThreadSummary
    var onOpenThread: () -> Void
    var onOpenMedia: (NeechanAPI.Attachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let attachment = thread.opPost.files.first {
                    MediaTapTarget(
                        attachment: attachment,
                        side: nil,
                        count: thread.opPost.files.count,
                        action: onOpenMedia
                    )
                } else {
                    Button(action: onOpenThread) {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .background(.quaternary)
                            .overlay {
                                Image(systemName: "text.alignleft")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .buttonStyle(.plain)
                }
                if thread.opPost.isSticky {
                    PinBadge()
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .clipped()

            Button(action: onOpenThread) {
                VStack(alignment: .leading, spacing: 3) {
                    ThreadTitle(thread: thread)
                        .lineLimit(2)
                    ThreadFooter(thread: thread)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 16))
    }
}

/// A thumbnail that opens its own media rather than the thread around it.
private struct MediaTapTarget: View {
    let attachment: NeechanAPI.Attachment
    let side: CGFloat?
    /// How many files the opening post carries, so a stack can say so.
    ///
    /// The opening post's own count, deliberately not `ThreadSummary.filesCount`
    /// — that is the whole thread's total, and the gallery this opens holds
    /// only the opening post's files, so the thread's number would promise
    /// media that is not there until the reader goes inside.
    var count: Int = 1
    var action: (NeechanAPI.Attachment) -> Void

    var body: some View {
        Button {
            action(attachment)
        } label: {
            ThumbnailView(attachment: attachment, side: side, attachmentCount: count)
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            attachment.isVideo
                ? Text("Plays this video", bundle: .module)
                : Text("Opens this image", bundle: .module)
        )
    }
}

// MARK: Pieces

private struct ThreadTitle: View {
    @Environment(AppServices.self) private var services

    let thread: ThreadSummary

    /// True once the comment has been read and turned out to start with the
    /// subject, which is how the site writes a post that was given no subject.
    @State private var echoesComment = false

    var body: some View {
        let subject = thread.opPost.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        Group {
            if subject.isEmpty || echoesComment {
                // Nothing at all: a thread with no subject of its own is its
                // opening post, and a bold line saying only its number is a
                // heading that carries none of the meaning a heading should.
                EmptyView()
            } else {
                Text(subject)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        // The same parse the preview underneath uses, and cached with it, so
        // asking this question costs nothing beyond the comparison.
        .task(id: thread.num) {
            guard !subject.isEmpty else { return }
            let comment = await PostPreview.text(for: thread.opPost, site: services.site)
            echoesComment = ThreadSubject.echoes(subject, comment: comment)
        }
    }
}

/// The opening post's text, parsed off the main actor so scrolling stays smooth.
private struct ThreadPreviewText: View {
    @Environment(AppServices.self) private var services

    let post: Post
    let lineLimit: Int

    @State private var text = ""

    var body: some View {
        Text(text)
            .font(.footnote)
            // Full strength: most threads on this board have no subject of
            // their own, so this text is the whole of what the card says. Grey
            // made it read as a caption for a heading that is not there.
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
            // Takes the height its own lines need instead of the height the row
            // offers: beside a thumbnail the row is only as tall as the picture,
            // and the text was being cut to fit that rather than to its limit.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: post.num) {
                text = await PostPreview.text(for: post, site: services.site)
            }
    }
}

private struct ThreadFooter: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(spacing: 8) {
            Count(value: thread.replyCount, systemImage: "bubble.left")
                // A bare number tells a VoiceOver reader nothing, and it is also
                // how the UI tests find a thread with a conversation in it.
                .accessibilityIdentifier("thread-replies")
                .accessibilityLabel(Text("\(thread.replyCount) replies", bundle: .module))

            if thread.filesCount > 0 {
                Count(value: thread.filesCount, systemImage: "photo")
                    .accessibilityLabel(Text("\(thread.filesCount) files", bundle: .module))
            }
            if thread.opPost.isClosed {
                Image(systemName: "lock.fill")
            }
            if thread.opPost.isEndless {
                Image(systemName: "arrow.trianglehead.2.clockwise")
            }

            Spacer(minLength: 0)

            Text(thread.opPost.postedAt, format: .relative(presentation: .numeric))
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}

/// A number with its icon after it.
///
/// The count is what a reader scans for, so it leads; the icon only says which
/// count it is.
private struct Count: View {
    let value: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "\(value)")
            Image(systemName: systemImage)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.caption2)
            .padding(5)
            .background(.thinMaterial, in: .circle)
    }
}

/// Parses a post body once and caches the plain text, so a list can show
/// previews without re-parsing HTML on every redraw.
///
/// The single place a board's opening posts are parsed. The row previews, the
/// autohide rules and the filter field all used to parse them separately, and
/// the last two did it on the main actor on every pass of the list's body.
enum PostPreview {
    private static let cache = PreviewCache()

    static func text(for post: Post, site: Imageboard) async -> String {
        await cache.text(for: post, site: site)
    }

    /// Which of these threads the rules hide, parsing each opening post at most
    /// once.
    static func hiddenThreadNums(
        in threads: [ThreadSummary],
        onBoard board: BoardRef,
        rules: [AutohideRuleValue]
    ) async -> Set<Int> {
        await cache.hiddenThreadNums(in: threads, onBoard: board, rules: rules)
    }

    /// The threads matching a filter, parsing each opening post at most once.
    static func filter(
        _ threads: [ThreadSummary],
        matching query: String,
        site: Imageboard
    ) async -> [ThreadSummary] {
        await cache.filter(threads, matching: query, site: site)
    }

    private actor PreviewCache {
        private var entries: [Int: String] = [:]

        func text(for post: Post, site: Imageboard) -> String {
            if let cached = entries[post.num] { return cached }
            // Built per call rather than held: it is one stored field, and the
            // board being previewed can change imageboard under this cache.
            let parsed = CommentHTMLParser(site: site)
                .parse(post.comment, inThread: post.threadNum, onBoard: post.board)
                .plainText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A thread list holds a few hundred rows at most; keep the cache
            // bounded so a long session does not accumulate every board visited.
            if entries.count > 600 { entries.removeAll(keepingCapacity: true) }
            entries[post.num] = parsed
            return parsed
        }

        func hiddenThreadNums(
            in threads: [ThreadSummary],
            onBoard board: BoardRef,
            rules: [AutohideRuleValue]
        ) -> Set<Int> {
            FilterEngine.hiddenThreadNums(
                in: threads.map(\.opPost),
                onBoard: board,
                rules: rules,
                commentText: { self.text(for: $0, site: board.site) }
            )
        }

        func filter(
            _ threads: [ThreadSummary],
            matching query: String,
            site: Imageboard
        ) -> [ThreadSummary] {
            CatalogRepository.filter(threads, matching: query) { self.text(for: $0, site: site) }
        }
    }
}

/// A thread the reader hid, shown only because they asked to see what is
/// hidden.
///
/// Deliberately unlike every other row: one dim line with no thumbnail, no
/// counts and no way into the thread. If a hidden thread looked like the rest,
/// turning the setting on would look the same as hiding nothing at all.
struct HiddenThreadStub: View {
    let title: String
    /// True when an autohide rule hid it rather than the reader.
    ///
    /// Such a thread cannot be brought back from here: the rule would hide it
    /// again on the next load, so the stub says where to go instead.
    var isHiddenByRule = false
    /// Brings the thread back.
    var onUnhide: () -> Void

    var body: some View {
        Button(action: onUnhide) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(isHiddenByRule ? "By a rule" : "Unhide", bundle: .module)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isHiddenByRule)
        .accessibilityIdentifier("hidden-thread")
        .accessibilityLabel(Text("Hidden thread, \(title)", bundle: .module))
        .accessibilityHint(
            isHiddenByRule
                ? Text("Hidden by an autohide rule", bundle: .module)
                : Text("Brings it back", bundle: .module)
        )
    }
}
