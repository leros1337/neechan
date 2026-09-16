import NeechanAPI
import NeechanCore
import SwiftUI

/// A thread: its posts, with quote previews stacked above them.
public struct ThreadView: View {
    private let key: ThreadKey
    private let scrollTarget: Int?
    /// Read the copy on the device rather than fetching the thread.
    private let isOfflineSource: Bool

    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @State private var model: ThreadViewModel?
    @State private var scrollPosition = ScrollPosition()
    @State private var galleryStart: GalleryStart?
    @State private var replyTarget: ReplyTarget?
    @State private var isShowingHiddenPosts = false
    @State private var isSaving = false
    @State private var isShowingGalleryGrid = false
    @State private var browserLink: BrowserLink?
    /// The post at the top of the screen, which is what gets remembered.
    @State private var topVisiblePostNum: Int?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    public init(key: ThreadKey, scrollTo: Int? = nil, offline: Bool = false) {
        self.key = key
        self.scrollTarget = scrollTo
        self.isOfflineSource = offline
    }

    public var body: some View {
        Group {
            if let model {
                loaded(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.snapshot.meta.title ?? "/\(key.board)/\(key.threadNum)")
        .inlineNavigationTitle()
        .task {
            let model = self.model ?? ThreadViewModel(key: key, services: services)
            self.model = model
            await model.start(offline: isOfflineSource)
            await model.refreshSavedState()
            restoreScrollPosition(model)
        }
        // Polls on the reader's interval while the thread is open. A saved copy
        // has nothing to poll.
        .task(id: services.settings.autoRefreshIntervalSeconds) {
            let seconds = services.settings.autoRefreshIntervalSeconds
            guard seconds > 0, !isOfflineSource else { return }
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
                await model?.refresh()
            }
        }
        .task {
            // Lives as long as the screen: picks up refreshes started elsewhere.
            await model?.observeUpdates()
        }
    }

    @ViewBuilder
    private func loaded(_ model: ThreadViewModel) -> some View {
        @Bindable var model = model

        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.visiblePosts) { post in
                    if model.showsUnreadDivider(before: post.num) {
                        NewPostsDivider()
                    }

                    if model.isHidden(post.num) {
                        HiddenPostStub(
                            post: post,
                            indexInThread: model.snapshot.indexInThread(of: post),
                            onReveal: { model.revealedHiddenPosts.insert(post.num) }
                        )
                        .id(post.num)
                    } else {
                    PostCellView(
                        post: post,
                        content: model.snapshot.content(of: post.num),
                        backlinks: model.snapshot.index.backlinks(to: post.num),
                        isOwn: model.snapshot.isOwn(post.num),
                        repliesToOwn: model.snapshot.repliesToOwnPost(post.num),
                        isDeleted: model.snapshot.isDeleted(post.num),
                        isNew: model.newPostNums.contains(post.num),
                        revealSpoilers: model.isRevealed(post.num),
                        indexInThread: model.snapshot.indexInThread(of: post),
                        onOpenReplies: { model.repliesSheetPostNum = post.num },
                        onOpenAttachment: { attachment in
                            openGallery(at: attachment, in: model)
                        },
                        onReply: { replyTarget = ReplyTarget(quoting: post.num) },
                        onHide: { rule in Task { await model.hide(rule) } },
                        postURL: DvachLinks.post(
                            board: key.board,
                            threadNum: key.threadNum,
                            postNum: post.num,
                            on: services.settings.domain
                        )
                    )
                    .id(post.num)
                    }
                }
            }
            // Marks the posts as the scroll targets, which is what lets the
            // scroll view report which of them are on screen.
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // Anchored to the top, which is both where a jump puts a post and how
        // the position reports which post the reader is on.
        .scrollPosition($scrollPosition, anchor: .top)
        // A fallback for the post at the top: the position's own view id is
        // precise but only exists once the scroll view has settled on one.
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.6) { visible in
            topVisiblePostNum = visible.first
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await model.refresh(userInitiated: true) }
        // New posts land at the bottom, which is where the reader already is,
        // so the thread also refreshes by pulling up past its end.
        .pullUpToRefresh { await model.refresh(userInitiated: true) }
        // Searching a thread belongs in the thread. Sending the reader to the
        // search tab lost their place and their way back.
        .searchableInPlace(
            text: $model.searchQuery,
            prompt: Text("Search in thread", bundle: .module)
        )
        // The field is tucked above the content, the way iOS hides search until
        // it is pulled down, so the menu offers an explicit way in.
        .searchFocused($isSearchFocused)
        .overlay { statusOverlay(model) }
        .overlay(alignment: .bottom) { refreshToast(model) }
        .overlay(alignment: .bottom) { quoteStatusToast(model) }
        .internalBrowser(link: $browserLink)
        .sheet(isPresented: $isShowingGalleryGrid) {
            GalleryGridView(items: model.snapshot.galleryItems) { postNum in
                isShowingGalleryGrid = false
                scrollToPost(postNum)
            }
        }
        .sheet(item: Binding(
            get: { model.repliesSheetPostNum.map(RepliesSheetTarget.init) },
            set: { model.repliesSheetPostNum = $0?.postNum }
        )) { target in
            RepliesSheet(
                rootPostNum: target.postNum,
                snapshot: model.snapshot,
                onOpenOutside: { action in handle(action, model: model) }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingHiddenPosts) {
            HiddenPostsSheet(thread: key) { await model.refreshHiddenPosts() }
        }
        .sheet(item: $replyTarget) { target in
            ReplyFormView(board: key.board, thread: key.threadNum, quoting: target.quoting) { _ in
                Task { await model.refresh() }
            }
        }
        .toolbar { toolbar(model) }
        // Reading is a full-screen job: the tab bar under a thread only offers
        // ways out of it, and while scrolling it shrinks to a pill in the
        // corner that is easy to hit by accident. It comes back on the way out.
        .hidesTabBar()
        // Inset rather than overlaid, so the buttons always clear the edge of
        // the screen, and with no spacing so they sit as low as they can.
        .safeAreaInset(edge: .bottom, spacing: 0) { threadControls(model) }
        .onDisappear {
            let postNum = currentTopPostNum
            Task {
                await model.markRead()
                await model.rememberPosition(postNum)
            }
        }
        // Leaving the app is leaving the thread as far as the reader is
        // concerned, and `onDisappear` does not run for it.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            let postNum = currentTopPostNum
            Task { await model.rememberPosition(postNum) }
        }
        .fullScreenCoverCompat(item: $galleryStart) { start in
            GalleryView(
                items: start.items,
                startIndex: start.index,
                services: services,
                onGoToPost: { postNum in
                    galleryStart = nil
                    scrollToPost(postNum)
                }
            )
        }
        // Attached last, so it sits above the reply bar rather than under it.
        // While a quote is open the bar is behind the scrim and inert, which is
        // what makes the popup feel like a layer of its own.
        .overlay { quoteOverlay(model) }
        // Applied last, so it covers the overlays as well as the posts. An
        // overlay is a sibling of the view it decorates, not a child, so a
        // handler installed further up does not reach it: that is why a `>>`
        // inside an open quote did nothing at all.
        .environment(\.openURL, OpenURLAction { url in
            handle(url, model: model)
            return .handled
        })
    }

    /// The thread's own address on the site, for sharing and opening.
    private var threadURL: URL? {
        DvachLinks.thread(
            board: key.board,
            threadNum: key.threadNum,
            on: services.settings.domain
        )
    }

    /// Jump-to-latest and Reply, as two small buttons in the corner.
    ///
    /// Not the tab view's bottom accessory: that container always claims the
    /// whole width the tab bar leaves, which is far too much chrome for two
    /// buttons.
    @ViewBuilder
    private func threadControls(_ model: ThreadViewModel) -> some View {
        if !model.isSearching, !model.snapshot.isEmpty {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    Button {
                        scrollToNewestPost(model)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(Text("Latest post", bundle: .module))

                    if !model.snapshot.meta.isClosed, !model.snapshot.meta.isDeleted {
                        Button {
                            replyTarget = ReplyTarget(quoting: nil)
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel(Text("Reply", bundle: .module))
                    }
                }
                // No bottom padding: with the tab bar gone the buttons sit on
                // the safe area itself, which is as low as the thumb reaches.
                .padding(.trailing, 12)
            }
        }
    }

    /// Brings a post into view, once whatever was over the thread has gone.
    ///
    /// The scroll is left a moment: asking for it while a cover is still on
    /// screen lands on a list that is not laid out yet, and nothing moves.
    private func scrollToPost(_ postNum: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.snappy) {
                scrollPosition.scrollTo(id: postNum, anchor: .top)
            }
        }
    }

    /// Scrolls to the newest post in the thread.
    private func scrollToNewestPost(_ model: ThreadViewModel) {
        guard let last = model.visiblePosts.last?.num else { return }
        withAnimation(.snappy) {
            scrollPosition.scrollTo(id: last, anchor: .bottom)
        }
    }

    /// Opens the gallery on the tapped file, with the whole thread behind it so
    /// the reader can swipe through every attachment.
    private func openGallery(at attachment: NeechanAPI.Attachment, in model: ThreadViewModel) {
        let items = model.snapshot.galleryItems
        guard let index = items.firstIndex(where: { $0.attachment.path == attachment.path })
        else { return }
        galleryStart = GalleryStart(items: items, index: index)
    }

    // MARK: Pieces

    @ToolbarContentBuilder
    private func toolbar(_ model: ThreadViewModel) -> some ToolbarContent {
        // Sharing is its own capsule: it is the action readers reach for most
        // after reading, and burying it in a menu costs a tap every time.
        if let url = threadURL {
            ToolbarItem(placement: .trailingBar) {
                ShareLink(item: url, subject: Text(model.snapshot.meta.title)) {
                    Label {
                        Text("Share link", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        ToolbarItem(placement: .trailingBar) {
            Menu {
                Button {
                    Task { await model.toggleFavorite() }
                } label: {
                    Label {
                        Text(model.isFavorite ? "Remove from favorites" : "Add to favorites", bundle: .module)
                    } icon: {
                        Image(systemName: model.isFavorite ? "star.fill" : "star")
                    }
                }
                Button {
                    isSearchFocused = true
                } label: {
                    Label {
                        Text("Search in thread", bundle: .module)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                Button {
                    isShowingGalleryGrid = true
                } label: {
                    Label {
                        Text("Gallery", bundle: .module)
                    } icon: {
                        Image(systemName: "photo.on.rectangle")
                    }
                }
                .disabled(model.snapshot.galleryItems.isEmpty)

                if !model.isOffline {
                    Button {
                        Task { await model.reload(userInitiated: true) }
                    } label: {
                        Label {
                            Text("Reload", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Menu {
                        Button {
                            Task { await save(model, includingFiles: false) }
                        } label: {
                            Text("Text and thumbnails", bundle: .module)
                        }
                        Button {
                            Task { await save(model, includingFiles: true) }
                        } label: {
                            Text("Everything, including files", bundle: .module)
                        }
                    } label: {
                        Label {
                            Text(model.isSaved ? "Update saved copy" : "Save for offline", bundle: .module)
                        } icon: {
                            Image(systemName: model.isSaved ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                    }
                }
                if let url = threadURL {
                    Section {
                        LinkActionsMenu(url: url, title: model.snapshot.meta.title)
                    }
                }
                if !model.hiddenPostNums.isEmpty {
                    Button {
                        isShowingHiddenPosts = true
                    } label: {
                        Label {
                            Text("\(model.hiddenPostNums.count) hidden posts", bundle: .module)
                        } icon: {
                            Image(systemName: "eye.slash")
                        }
                    }
                }
                Section {
                    if model.isSearching {
                        Text("\(model.visiblePosts.count) matches", bundle: .module)
                    }
                    Text("\(model.snapshot.meta.postsCount) posts", bundle: .module)
                    Text("\(model.snapshot.meta.filesCount) files", bundle: .module)
                    if model.snapshot.meta.uniquePosters > 0 {
                        Text("\(model.snapshot.meta.uniquePosters) posters", bundle: .module)
                    }
                }
            } label: {
                Label {
                    Text("Thread actions", bundle: .module)
                } icon: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    /// Says what a `>>` tap is doing when it cannot simply show the post.
    ///
    /// A quote can point at a post this thread does not hold, and that post can
    /// be gone. Saying so is the difference between a missing post and a link
    /// that appears not to work.
    @ViewBuilder
    private func quoteStatusToast(_ model: ThreadViewModel) -> some View {
        if let status = model.quoteStatus {
            HStack(spacing: 8) {
                switch status {
                case .loading(let postNum):
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening post №\(postNum)…", bundle: .module)
                case .missing(let postNum):
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Post №\(postNum) is gone", bundle: .module)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(in: .capsule)
            .padding(.bottom, 56)
            .accessibilityIdentifier("quote-status")
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: model.quoteStatus) {
                guard case .missing = status else { return }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.snappy) { model.dismissQuoteStatus() }
            }
        }
    }

    /// Tells the reader what the last refresh found, then gets out of the way.
    @ViewBuilder
    private func refreshToast(_ model: ThreadViewModel) -> some View {
        if let announcement = model.lastRefresh {
            RefreshToast(
                failure: announcement.failure,
                newPostCount: announcement.newPostCount,
                replyToOwnCount: announcement.replyToOwnCount
            ) {
                if let destination = announcement.destinationPostNum {
                    scrollPosition.scrollTo(id: destination, anchor: .top)
                }
                model.dismissRefreshAnnouncement()
            }
            .padding(.bottom, 56)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: announcement.id) {
                // Long enough to read, short enough not to sit on the thread.
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.snappy) { model.dismissRefreshAnnouncement() }
            }
        }
    }

    /// Writes the thread to the device. Saving with files can take a while and
    /// a lot of space, so the two sizes are separate menu items rather than one
    /// button with a setting behind it.
    private func save(_ model: ThreadViewModel, includingFiles: Bool) async {
        isSaving = true
        defer { isSaving = false }
        _ = await model.save(includingFiles: includingFiles)
    }

    @ViewBuilder
    private func statusOverlay(_ model: ThreadViewModel) -> some View {
        switch model.loadState {
        case .loading where model.snapshot.isEmpty:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could not load the thread", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            } actions: {
                Button { Task { await model.load() } } label: {
                    Text("Try again", bundle: .module)
                }
                .buttonStyle(.glassProminent)
            }
        case .idle, .loading, .loaded:
            if model.isSearching && model.visiblePosts.isEmpty {
                ContentUnavailableView.search(text: model.searchQuery)
            } else if model.snapshot.meta.isDeleted {
                VStack {
                    Spacer()
                    Text("This thread is gone. You are reading a saved copy.", bundle: .module)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 20)
                }
            }
        }
    }

    /// Quoted posts float above the thread, newest on top, the way Dashchan
    /// stacks them.
    @ViewBuilder
    private func quoteOverlay(_ model: ThreadViewModel) -> some View {
        if let quoted = model.quotePopups.last {
            ZStack(alignment: .bottom) {
                // Tapping away closes the top quote, which is how readers expect
                // to get out of a stacked preview.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { model.dismissTopQuote() }
                    }

                QuotePopupView(
                    quoted: quoted,
                    depth: model.quotePopups.count,
                    onDismiss: {
                        withAnimation(.snappy(duration: 0.2)) { model.dismissTopQuote() }
                    },
                    onDismissAll: {
                        withAnimation(.snappy(duration: 0.2)) { model.dismissAllQuotes() }
                    },
                    onOpenAttachment: { attachment in openGallery(at: attachment, in: model) }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    private func handle(_ url: URL, model: ThreadViewModel) {
        handle(NeechanURL.action(for: url), model: model)
    }

    private func handle(_ action: NeechanURL.Action, model: ThreadViewModel) {
        switch action {
        case .post(let board, let threadNum, let postNum):
            Task {
                await model.showQuote(
                    board: board.isEmpty ? key.board : board,
                    threadNum: threadNum,
                    postNum: postNum
                )
            }
        case .toggleSpoilers(let postNum):
            model.toggleSpoilers(in: postNum)
        case .external(let url):
            // Links off the site open in the app unless the reader asked for
            // Safari, so a tap does not lose the thread.
            if services.settings.usesInternalBrowser {
                browserLink = BrowserLink(url: url)
            } else {
                openURL(url)
            }
        }
    }

    /// The post the thread is scrolled to.
    private var currentTopPostNum: Int? {
        scrollPosition.viewID(type: Int.self) ?? topVisiblePostNum
    }

    /// Puts the reader back where they were, or on the post they came for.
    ///
    /// A post asked for by the caller wins: following a link to a post and
    /// landing somewhere else instead would be a plain bug. The remembered
    /// position is only the fallback.
    private func restoreScrollPosition(_ model: ThreadViewModel) {
        let destination = [scrollTarget, model.rememberedPostNum]
            .compactMap { $0 }
            .first { model.snapshot.post(num: $0) != nil }
        guard let destination else { return }
        scrollPosition.scrollTo(id: destination, anchor: .top)
    }
}

/// Opens the reply form, optionally quoting a post.
private struct ReplyTarget: Identifiable {
    let quoting: Int?
    var id: String { quoting.map(String.init) ?? "new" }
}

/// Identifiable wrapper so the replies sheet can be driven by a post number.
private struct RepliesSheetTarget: Identifiable {
    let postNum: Int
    var id: Int { postNum }

    init(_ postNum: Int) {
        self.postNum = postNum
    }
}
