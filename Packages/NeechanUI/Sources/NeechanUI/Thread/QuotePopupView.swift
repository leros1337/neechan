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
    var onDismiss: () -> Void
    var onDismissAll: () -> Void

    @Environment(\.neechanTheme) private var theme
    @State private var revealSpoilers = false
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
                QuotedAttachmentsRow(attachments: quoted.post.files)
            }
            quotedBody
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .frame(maxWidth: 560)
        .accessibilityIdentifier("quote-popup")
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

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ThumbnailView(attachment: attachment, side: 88)
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
                palette: .init(theme: theme)
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

    @Environment(\.dismiss) private var dismiss
    /// Post numbers pushed on top of the root list.
    @State private var path: [Int] = []
    @State private var revealedSpoilers: Set<Int> = []

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
            isDeleted: snapshot.isDeleted(post.num),
            isNew: false,
            revealSpoilers: revealedSpoilers.contains(post.num),
            indexInThread: snapshot.indexInThread(of: post),
            onOpenReplies: {}
        )
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
