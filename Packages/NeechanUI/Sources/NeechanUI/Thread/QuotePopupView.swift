import NeechanAPI
import NeechanCore
import SwiftUI

/// A quoted post, floating above the thread.
///
/// Glass here is deliberate: the popup is a control-layer surface sitting over
/// the content, which is exactly what the material is for.
struct QuotePopupView: View {
    let quoted: ThreadViewModel.QuotedPost
    /// How many popups are stacked, shown so the reader knows how deep they are.
    let depth: Int
    /// How many posts in this thread replied to the quoted one.
    ///
    /// Meaningless for a post fetched from another thread, which is why the
    /// pill is gated on `isRemote` as well. A post number is unique only within
    /// a board, so a foreign post can carry a number this thread also uses —
    /// and the index will then answer confidently with the *local* post's
    /// replies. Counting it would put one post's replies on another.
    let replyCount: Int
    /// Posts the reader wrote in the thread behind this popup, so a `>>N` in the
    /// quoted body can be marked. Empty when the quote came from another thread.
    let ownPostNums: Set<Int>
    /// Opens the window listing those replies.
    var onOpenReplies: () -> Void = {}
    var onDismiss: () -> Void
    var onDismissAll: () -> Void
    /// A file in the quoted post was tapped.
    var onOpenAttachment: (NeechanAPI.Attachment) -> Void = { _ in }

    @Environment(\.neechanTheme) private var theme
    @State private var revealSpoilers = false
    /// How far the reader has dragged the card down to put it away.
    @State private var dragOffset: CGFloat = 0
    /// Natural height of the quoted text, measured off-screen.
    @State private var textHeight: CGFloat = 0

    private static let renderer = PostTextRenderer()
    /// Past this the quote scrolls instead of growing.
    private static let maximumTextHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !quoted.post.files.isEmpty {
                // Smaller than in the thread: a preview is about the text, and a
                // full-size thumbnail pushed the quote off the screen.
                QuotedAttachmentsRow(attachments: quoted.post.files, onSelect: onOpenAttachment)
            }
            quotedBody

            // The same pill the post carries in the thread. Never for a post
            // fetched from elsewhere: its number can collide with one of this
            // thread's, and the count would then belong to a different post.
            if !quoted.isRemote, replyCount > 0 {
                RepliesButton(count: replyCount, action: onOpenReplies)
                    .accessibilityIdentifier("quote-popup-replies")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .frame(maxWidth: 560)
        // Follows the finger and fades as it goes, so the card reads as
        // something being put down rather than as a panel that jumped.
        .offset(y: dragOffset)
        .opacity(1 - min(0.4, dragOffset / 420))
        // The whole card takes touches, not only the parts with something drawn
        // on them. Padding and the gaps between rows belong to no view, so a
        // drag begun there reached nothing at all.
        .contentShape(.rect(cornerRadius: 20))
        // A plain gesture, not a simultaneous one: a long quote scrolls inside
        // the card, and a child scroll view keeps the drags that start in it.
        // Dragging anywhere else, the header included, puts the card away.
        .gesture(swipeAway)
        .accessibilityIdentifier("quote-popup")
    }

    /// Dragging the card down closes it.
    ///
    /// The close button is a small target in the top corner of a card that sits
    /// at the bottom of the screen, which is the wrong end for a thumb.
    private var swipeAway: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Downward only: there is nothing above the card to go to.
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                // A flick counts as well as a long pull, so the card can be
                // thrown away without dragging it the whole distance.
                let flicked = value.predictedEndTranslation.height > 260
                if dragOffset > 90 || flicked {
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.22)) { dragOffset = 0 }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "№\(quoted.post.num)")
                .font(.caption.weight(.semibold).monospacedDigit())
            if quoted.isRemote {
                Text("Another thread", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if depth > 1 {
                Text(verbatim: "\(depth)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.18), in: .capsule)
            }
            Spacer(minLength: 0)

            if depth > 1 {
                CloseButton(
                    systemImage: "xmark.circle",
                    label: Text("Close all", bundle: .module),
                    action: onDismissAll
                )
            }
            CloseButton(
                systemImage: "xmark",
                label: Text("Close", bundle: .module),
                action: onDismiss
            )
        }
        // The header is taller than its text so the close targets can be a full
        // 44 points without the popup growing awkwardly around them.
        .frame(minHeight: 44)
    }

    /// The quoted text, sized to itself.
    ///
    /// A `maxHeight` frame takes the whole height it is offered and centres its
    /// content, which left short quotes floating in the middle of a tall panel.
    /// Measuring the text and giving the box that exact height avoids it, and
    /// scrolling only appears once the quote is genuinely long.
    @ViewBuilder
    private var quotedBody: some View {
        let isScrollable = textHeight > Self.maximumTextHeight

        Group {
            if isScrollable {
                ScrollView { quotedText }
                    .frame(height: Self.maximumTextHeight)
            } else {
                quotedText
            }
        }
        .background { textHeightProbe }
    }

    private var quotedText: some View {
        Text(body(for: quoted))
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A hidden copy laid out at its natural height, purely to measure it.
    private var textHeightProbe: some View {
        Text(body(for: quoted))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                if abs(height - textHeight) > 0.5 {
                    textHeight = height
                }
            }
    }

    /// Attachments at preview size.
    private struct QuotedAttachmentsRow: View {
        let attachments: [NeechanAPI.Attachment]
        var onSelect: (NeechanAPI.Attachment) -> Void

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        Button {
                            onSelect(attachment)
                        } label: {
                            ThumbnailView(attachment: attachment, side: 88)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 88)
        }
    }

    /// A close control with a real hit target.
    ///
    /// Drawn as a small glyph but tappable across 44 points: the first version
    /// made the glyph itself the only target, which readers could not hit.
    private struct CloseButton: View {
        let systemImage: String
        let label: Text
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    private func body(for quoted: ThreadViewModel.QuotedPost) -> AttributedString {
        Self.renderer.render(
            quoted.content,
            options: .init(
                postNum: quoted.post.num,
                revealSpoilers: revealSpoilers,
                palette: .init(theme: theme),
                ownPostNums: ownPostNums
            )
        )
    }
}

/// A post's replies, each on its own card.
///
/// Quotes inside a reply push another screen rather than replacing this one, so
/// going back returns to the list you came from instead of closing everything.
struct RepliesSheet: View {
    /// The post whose replies open the window.
    let rootPostNum: Int
    let snapshot: ThreadSnapshot
    /// Called for a destination this window cannot show: a post in another
    /// thread, or a link out to the web.
    var onOpenOutside: (NeechanURL.Action) -> Void
    /// Claims a post as the reader's own, or takes the claim back. Handled by
    /// the thread behind this window, which owns the snapshot the cards read.
    var onToggleOwn: (Int, Bool) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    /// Post numbers pushed on top of the root list.
    @State private var path: [Int] = []
    @State private var revealedSpoilers: Set<Int> = []
    /// A file tapped in one of the cards, shown in the viewer over this window.
    ///
    /// The cards here used to be built without a way to open their files, so a
    /// picture or a clip in a reply did nothing when tapped.
    @State private var galleryStart: GalleryStart?

    var body: some View {
        NavigationStack(path: $path) {
            repliesList(to: rootPostNum)
                .navigationTitle(
                    Text("\(snapshot.index.backlinks(to: rootPostNum).count) replies", bundle: .module)
                )
                .inlineNavigationTitle()
                .navigationDestination(for: Int.self) { postNum in
                    quotedPost(postNum)
                        .navigationTitle(Text(verbatim: "\u{2116}\(postNum)"))
                        .inlineNavigationTitle()
                        // A pushed screen gets its own toolbar, so the way out
                        // has to be repeated or it disappears once you go deeper.
                        .toolbar { doneButton }
                }
                .toolbar { doneButton }
        }
        .fullScreenCoverCompat(item: $galleryStart) { start in
            GalleryView(
                items: start.items,
                startIndex: start.index,
                services: services,
                onGoToPost: { postNum in
                    // Within this window: the post is pushed the way a quote
                    // is, so Back returns to the list it came from.
                    galleryStart = nil
                    if snapshot.post(num: postNum) != nil { path.append(postNum) }
                }
            )
        }
        .environment(\.openURL, OpenURLAction { url in
            handle(NeechanURL.action(for: url))
            return .handled
        })
    }

    @ToolbarContentBuilder
    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Text("Done", bundle: .module)
            }
        }
    }

    // MARK: Screens

    /// The replies to one post.
    private func repliesList(to postNum: Int) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(replies(to: postNum)) { post in
                    card(for: post)
                }
            }
            .padding(12)
        }
    }

    /// A quoted post, followed by its own replies.
    @ViewBuilder
    private func quotedPost(_ postNum: Int) -> some View {
        if let post = snapshot.post(num: postNum) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    card(for: post)

                    let nested = replies(to: postNum)
                    if !nested.isEmpty {
                        Text("\(nested.count) replies", bundle: .module)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(nested) { reply in
                            card(for: reply)
                        }
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text("That post is not in this thread", bundle: .module)
                } icon: {
                    Image(systemName: "questionmark.bubble")
                }
            }
        }
    }

    private func card(for post: Post) -> some View {
        PostCellView(
            post: post,
            content: snapshot.content(of: post.num),
            // Replies are reached by tapping a quote, not by another count
            // inside a window that is already about replies.
            backlinks: [],
            isOwn: snapshot.isOwn(post.num),
            repliesToOwn: false,
            ownPostNums: snapshot.ownPostNums,
            isDeleted: snapshot.isDeleted(post.num),
            isNew: false,
            revealSpoilers: revealedSpoilers.contains(post.num),
            indexInThread: snapshot.indexInThread(of: post),
            onOpenReplies: {},
            onOpenAttachment: { attachment in openGallery(at: attachment) },
            onToggleOwn: { onToggleOwn(post.num, !snapshot.isOwn(post.num)) }
        )
    }

    /// Opens the viewer on a file, with the whole thread's files behind it so
    /// the reader can page on from there, as they can from the thread.
    private func openGallery(at attachment: NeechanAPI.Attachment) {
        let items = snapshot.galleryItems
        guard let index = items.firstIndex(where: { $0.attachment.path == attachment.path }) else { return }
        galleryStart = GalleryStart(items: items, index: index)
    }

    private func replies(to postNum: Int) -> [Post] {
        snapshot.index.backlinks(to: postNum).compactMap { snapshot.post(num: $0) }
    }

    // MARK: Actions

    private func handle(_ action: NeechanURL.Action) {
        switch action {
        case .toggleSpoilers(let postNum):
            if revealedSpoilers.contains(postNum) {
                revealedSpoilers.remove(postNum)
            } else {
                revealedSpoilers.insert(postNum)
            }

        case .post(_, _, let postNum):
            if snapshot.post(num: postNum) != nil {
                // Push, so Back returns to the list this came from.
                path.append(postNum)
            } else {
                // Another thread is the thread view's job, not this window's.
                dismiss()
                onOpenOutside(action)
            }

        case .external:
            dismiss()
            onOpenOutside(action)
        }
    }
}
