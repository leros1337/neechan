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
    @State private var reportTarget: ReportTarget?
    @State private var hasReported = false
    @State private var isShowingHiddenPosts = false
    @State private var isSaving = false
    @State private var isShowingGalleryGrid = false
    @State private var doomscrollStart: GalleryStart?
    /// Whether the favorites are open over the thread.
    @State private var isShowingFavorites = false
    @State private var browserLink: BrowserLink?
    /// The post at the top of the screen, which is what gets remembered.
    ///
    /// Held in a reference rather than in the `@State` value itself: the scroll
    /// view reports this continuously while scrolling, and every store into
    /// `@State` invalidates the view that owns it, so tracking the top post used
    /// to re-render the whole thread as it moved. Nothing draws from this; it is
    /// read once, on the way out.
    @State private var topPost = TopPostBox()
    @FocusState private var isSearchFocused: Bool
    /// Whether the thread is the screen being read, rather than one left
    /// underneath whatever was opened from it.
    @State private var isVisible = false
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
        // Polls while the thread is the screen being read. Keyed on all three
        // conditions, so a change to any of them cancels the loop and starts a
        // fresh one: a `task` is torn down when its view goes away, which is not
        // the same as the reader leaving. Before this, every thread left on the
        // navigation stack kept its own timer, and they all kept running with
        // the app in the background.
        .task(id: autoRefreshKey) { await autoRefresh() }
        // Lives as long as the screen: picks up refreshes started elsewhere,
        // such as a reply this device sent.
        //
        // Keyed on the model existing, because the task that builds it starts at
        // the same moment as this one: without the key this ran once, while the
        // model was still nil, and listened to nothing.
        .task(id: model == nil) {
            await model?.observeUpdates()
        }
        // Narrowing the thread to a search belongs here rather than in a
        // property observer on the query: the search field writes that binding
        // during a view update, and recomputing observed state from inside one
        // is undefined behaviour. Keyed on the snapshot too, so posts arriving
        // during a search are matched against it.
        .task(id: SearchKey(query: model?.searchQuery, generation: model?.snapshot.generation)) {
            await model?.updateSearch()
        }
    }

    @ViewBuilder
    private func loaded(_ model: ThreadViewModel) -> some View {
        @Bindable var model = model
        // Read once. The list, the toolbar's match count and the empty-search
        // overlay all want it, and it filters every post in the thread.
        let posts = model.visiblePosts
        let asCards = services.settings.postsViewMode == .cards

        ScrollView {
            // Cards float apart; a list runs together and lets the hairline
            // between two posts do the dividing the gap used to do.
            LazyVStack(spacing: asCards ? 10 : 0) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                    if model.showsUnreadDivider(before: post.num) {
                        NewPostsDivider()
                            .padding(.horizontal, asCards ? 0 : 12)
                            .padding(.vertical, asCards ? 0 : 8)
                    } else if !asCards, showsSeparator(above: index, in: posts, model: model) {
                        PostSeparator()
                    }

                    // One identity for the row, outside the branch. With `.id`
                    // inside each branch SwiftUI saw the same identity either
                    // way and kept the view it already had, so a post that had
                    // just been hidden went on drawing itself in full -- while
                    // every `>>N` pointing at it, read from the same set, was
                    // struck through correctly.
                    Group {
                        if model.isHidden(post.num) {
                            HiddenPostStub(
                                post: post,
                                indexInThread: model.snapshot.indexInThread(of: post),
                                onReveal: { model.revealedHiddenPosts.insert(post.num) }
                            )
                            .padding(.horizontal, asCards ? 0 : 12)
                            .padding(.vertical, asCards ? 0 : 6)
                        } else {
                            PostCellView(
                        post: post,
                        content: model.snapshot.content(of: post.num),
                        // Hidden replies are left out of both the count and the
                        // window it opens, so the two cannot disagree.
                        backlinks: model.visibleBacklinks(to: post.num),
                        isOwn: model.snapshot.isOwn(post.num),
                        repliesToOwn: model.snapshot.repliesToOwnPost(post.num),
                        ownPostNums: model.snapshot.ownPostNums,
                        hiddenPostNums: model.effectiveHiddenPostNums,
                        isDeleted: model.snapshot.isDeleted(post.num),
                        isNew: model.isNew(post.num),
                        revealSpoilers: model.isRevealed(post.num),
                        indexInThread: model.snapshot.indexInThread(of: post),
                        onOpenReplies: { model.repliesSheetPostNum = post.num },
                        onOpenAttachment: { attachment in
                            openGallery(at: attachment, in: model)
                        },
                        onReply: services.allowsPosting
                            ? { replyTarget = ReplyTarget(quoting: post.num) } : nil,
                        onHide: { rule in Task { await model.hide(rule) } },
                        onToggleOwn: {
                            Task {
                                await model.setOwned(
                                    !model.snapshot.isOwn(post.num), postNum: post.num
                                )
                            }
                        },
                        onReport: reportAction(for: post.num),
                        postURL: SiteLinks.post(
                            board: key.board,
                            threadNum: key.threadNum,
                            postNum: post.num,
                            on: services.settings.siteSelection
                        ),
                        style: asCards ? .card : .flat
                    )
                        }
                    }
                    .id(post.num)
                }
            }
            // Marks the posts as the scroll targets, which is what lets the
            // scroll view report which of them are on screen.
            .scrollTargetLayout()
            // Cards are inset as a group, the way they always were. A list
            // insets each row itself, so a separator can run the full width of
            // the column instead of stopping short.
            .padding(.horizontal, asCards ? 12 : 0)
            .padding(.vertical, 10)
            // A measure, rather than however wide the window happens to be.
            // On the inner display of an iPhone Duo -- and already in the
            // iPad detail column -- a post set edge to edge runs past the
            // length a reader can track back from. The same clamp the quote
            // popup has always used. The second frame is what centres it;
            // on a phone nothing is this wide, so nothing moves there.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        // Anchored to the top, which is both where a jump puts a post and how
        // the position reports which post the reader is on.
        .scrollPosition($scrollPosition, anchor: .top)
        // A fallback for the post at the top: the position's own view id is
        // precise but only exists once the scroll view has settled on one.
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.6) { visible in
            topPost.num = visible.first
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // New posts land at the bottom, which is where the reader already is,
        // so the thread refreshes by pulling up past its end.
        //
        // Pulling *down* deliberately does not, even though that is the usual
        // gesture. The top of a thread is where the search field is tucked
        // away, and a refresh control in the same place fought it for the same
        // drag: pulling down far enough left the field pushed halfway down an
        // empty screen, with the posts below it. The reader who wants a reload
        // without scrolling to the end has it in the thread's menu.
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
        .overlay { statusOverlay(model, posts: posts) }
        .overlay(alignment: .bottom) { refreshToast(model) }
        .overlay(alignment: .bottom) { quoteStatusToast(model) }
        .reportPresentation(
            board: key.board,
            thread: key.threadNum,
            target: $reportTarget,
            hasReported: $hasReported
        )
        .internalBrowser(link: $browserLink)
        .sheet(isPresented: $isShowingGalleryGrid) {
            GalleryGridView(items: model.snapshot.galleryItems) { postNum in
                isShowingGalleryGrid = false
                scrollToPost(postNum)
            }
            .duoPresentationPlacement(.trailing)
        }
        .sheet(item: repliesSheetTarget(model)) { target in
            RepliesSheet(
                rootPostNum: target.postNum,
                snapshot: model.snapshot,
                hiddenPostNums: model.effectiveHiddenPostNums,
                onOpenOutside: { action in handle(action, model: model) },
                onToggleOwn: { postNum, owned in
                    Task { await model.setOwned(owned, postNum: postNum) }
                }
            )
            .presentationDetents([.large])
            // Beside the thread on a display wide enough to hold both, which
            // is what these replies are: the thread is still the subject.
            // Trailing is also what tells the system to stack the sheet's own
            // bar down the side rather than across the top.
            .duoPresentationPlacement(.trailing)
        }
        .sheet(isPresented: $isShowingHiddenPosts) {
            HiddenPostsSheet(thread: key) { await model.refreshHiddenPosts() }
        }
        .sheet(item: $replyTarget) { target in
            ReplyFormView(board: key.board, thread: key.threadNum, quoting: target.quoting) { _ in
                Task { await model.refresh() }
            }
        }
        .sheet(isPresented: $isShowingFavorites) {
            FavoritesWindow()
                .presentationDetents([.large])
                .duoPresentationPlacement(.trailing)
        }
        .toolbar { toolbar(model, matchCount: posts.count) }
        // Reading is a full-screen job: the tab bar under a thread only offers
        // ways out of it, and while scrolling it shrinks to a pill in the
        // corner that is easy to hit by accident. It comes back on the way out.
        //
        // Set here, by the thread itself, and not from the shell: hiding it
        // there, from the navigation stack, does not take at all — the bar
        // stays up over the thread.
        .hidesTabBar()
        // Inset rather than overlaid, so the buttons always clear the edge of
        // the screen, and with no spacing so they sit as low as they can.
        .safeAreaInset(edge: .bottom, spacing: 0) { threadControls(model) }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
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
        .fullScreenCoverCompat(item: $doomscrollStart) { start in
            DoomscrollView(
                items: start.items,
                startIndex: start.index,
                services: services,
                onGoToPost: { postNum in
                    doomscrollStart = nil
                    scrollToPost(postNum)
                }
            )
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

    /// Whether the reader is actually looking at this thread.
    ///
    /// A window is presented over the thread rather than in place of it, so the
    /// view never disappears and `isVisible` stays true underneath it. Without
    /// this, a thread read in the window and the thread behind it would both
    /// poll, which is two threads' worth of requests for one reader.
    private var isReading: Bool { isVisible && !isShowingFavorites }

    /// What the auto-refresh loop depends on. A change to any of it restarts it.
    private var autoRefreshKey: AutoRefreshKey {
        AutoRefreshKey(
            seconds: services.settings.autoRefreshIntervalSeconds,
            isActive: scenePhase == .active,
            isVisible: isReading
        )
    }

    /// Re-reads the thread on the reader's interval, backing off while it is
    /// quiet.
    ///
    /// The interval the reader picked is the fastest they want to be told about
    /// a new post, not a promise to keep asking at that rate into the evening;
    /// a thread nobody has posted in is asked about progressively less often,
    /// and one new post puts it straight back to the chosen rate.
    private func autoRefresh() async {
        let seconds = services.settings.autoRefreshIntervalSeconds
        guard seconds > 0, !isOfflineSource, scenePhase == .active, isReading else { return }

        let base = Duration.seconds(seconds)
        var quietPolls = 0
        while !Task.isCancelled {
            let wait = PollBackoff.interval(
                base: base,
                quiet: quietPolls,
                cap: Self.autoRefreshCap,
                // Read each time round rather than observed: the answer only
                // has to be right by the next poll, and this saves an observer
                // living as long as the screen.
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            guard (try? await Task.sleep(for: wait)) != nil else { return }
            // Cellular, with the reader asking for Wi-Fi only. Waiting rather
            // than stopping, so it resumes by itself when they are back on
            // Wi-Fi.
            guard services.allowsAutomaticPolling else { continue }

            await model?.refresh()
            quietPolls = model?.newPostNums.isEmpty == false ? 0 : quietPolls + 1
        }
    }

    /// The longest the loop will ever wait. Past this a reader who wanted to be
    /// told would have pulled to refresh.
    private static let autoRefreshCap = Duration.seconds(300)

    /// The thread's own address on the site, for sharing and opening.
    private var threadURL: URL? {
        SiteLinks.thread(
            board: key.board,
            threadNum: key.threadNum,
            on: services.settings.siteSelection
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

                    if services.allowsPosting,
                       !model.snapshot.meta.isClosed, !model.snapshot.meta.isDeleted {
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

    /// Whether a hairline is drawn above the post at `index`.
    ///
    /// Not above the first post, and not where something already divides the
    /// two: the unread marker is a rule of its own, and a hidden post keeps its
    /// rounded chip, which draws its own edge -- a hairline beside either would
    /// be the same boundary twice.
    private func showsSeparator(above index: Int, in posts: [Post], model: ThreadViewModel) -> Bool {
        guard index > 0 else { return false }
        return !model.isHidden(posts[index].num) && !model.isHidden(posts[index - 1].num)
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
    /// Opens the feed on the thread's first video.
    ///
    /// Handed every attachment rather than only the videos: the feed does the
    /// filtering, because what counts as a video there is decided by what the
    /// player can actually open, which this module cannot ask.
    private func startDoomscroll(in model: ThreadViewModel) {
        doomscrollStart = GalleryStart(items: model.snapshot.galleryItems, index: 0)
    }

    private func openGallery(at attachment: NeechanAPI.Attachment, in model: ThreadViewModel) {
        let items = model.snapshot.galleryItems
        guard let index = items.firstIndex(where: { $0.attachment.path == attachment.path })
        else { return }
        galleryStart = GalleryStart(items: items, index: index)
    }

    // MARK: Pieces

    @ToolbarContentBuilder
    private func toolbar(_ model: ThreadViewModel, matchCount: Int) -> some ToolbarContent {
        // The favorites, over the thread rather than instead of it. This used
        // to be a share button, which was a second way to reach what the menu
        // below already offers; getting to another kept thread meant backing
        // out of this one to go looking, which nothing offered at all.
        ToolbarItem(placement: .trailingBar) {
            Button {
                isShowingFavorites = true
            } label: {
                Label {
                    Text("Favorites", bundle: .module)
                } icon: {
                    // A drawn symbol rather than an emoji, so it takes the
                    // tint and the weight of everything else on the bar.
                    Image(systemName: "paperplane")
                }
            }
            .accessibilityIdentifier("favorites-window")
        }
        ToolbarItem(placement: .trailingBar) {
            ThreadToolbarMenu(
                model: model,
                threadURL: threadURL,
                matchCount: matchCount,
                onSearch: { isSearchFocused = true },
                onShowGallery: { isShowingGalleryGrid = true },
                onShowDoomscroll: { startDoomscroll(in: model) },
                onShowHiddenPosts: { isShowingHiddenPosts = true },
                onReload: { Task { await model.reload(userInitiated: true) } },
                onSave: { includingFiles in
                    Task { await save(model, includingFiles: includingFiles) }
                }
            )
        }
    }

    /// The replies sheet's target, as something `sheet(item:)` can be driven by.
    ///
    /// A method rather than a `Binding(get:set:)` written inline. Built in the
    /// body it is one more thing for the type checker to solve inside a chain
    /// that is already at its limit, and it was what tipped the chain over when
    /// the report sheet joined it.
    private func repliesSheetTarget(_ model: ThreadViewModel) -> Binding<RepliesSheetTarget?> {
        Binding(
            get: { model.repliesSheetPostNum.map(RepliesSheetTarget.init) },
            set: { model.repliesSheetPostNum = $0?.postNum }
        )
    }

    /// Opens the report sheet for a post, or nil where the site takes no
    /// reports and the menu item should be left out.
    ///
    /// A method rather than a ternary in the cell's argument list: that list is
    /// already at the edge of what the type checker will solve in reasonable
    /// time, and an inline conditional producing an optional closure is what
    /// pushed it over.
    private func reportAction(for postNum: Int) -> (() -> Void)? {
        guard services.capabilities.reporting != .none else { return nil }
        return { reportTarget = ReportTarget(postNum: postNum) }
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
                case .restricted:
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                    // No button: this is a toast that takes itself away again,
                    // and a control on one is a control the reader has to race.
                    Text("That board is for adults. Turn on Adult 18+ in Restrictions.", bundle: .module)
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
                switch status {
                case .missing, .restricted: break
                case .loading: return
                }
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
    private func statusOverlay(_ model: ThreadViewModel, posts: [Post]) -> some View {
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
            if model.isSearching && posts.isEmpty {
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
                    replyCount: model.visibleBacklinks(to: quoted.post.num).count,
                    // Empty for a post fetched from elsewhere, for the same
                    // reason the reply count above is withheld: its references
                    // are numbered against another thread, where a number the
                    // reader owns here belongs to somebody else.
                    ownPostNums: quoted.isRemote ? [] : model.snapshot.ownPostNums,
                    hiddenPostNums: quoted.isRemote ? [] : model.effectiveHiddenPostNums,
                    onOpenReplies: { model.repliesSheetPostNum = quoted.post.num },
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
            // A link to a restricted board is refused here. It cannot be
            // refused once the browser is up: the sheet is a Safari view
            // controller, which offers no hook on what it navigates to.
            if let target = NavigationQueryParser.parse(
                url.absoluteString,
                site: services.site,
                currentBoard: nil
            ), !services.contentPolicy.allowsOpening(target) {
                return
            }
            // Links off the site open in the app so a tap does not lose the
            // thread -- unless the reader asked for Safari, or has not yet said
            // they are 18, in which case the link leaves rather than being
            // followed on a surface this app answers for.
            if services.settings.opensLinksInApp {
                browserLink = BrowserLink(url: url)
            } else {
                openURL(url)
            }
        }
    }

    /// The post the thread is scrolled to.
    private var currentTopPostNum: Int? {
        scrollPosition.viewID(type: Int.self) ?? topPost.num
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

/// Holds the post at the top of the screen without making it observed state.
///
/// A class so writing to it is not a write to `@State` itself: the value stored
/// in `@State` is the reference, and that never changes.
@MainActor
private final class TopPostBox {
    var num: Int?
}

/// What the in-thread search depends on.
private struct SearchKey: Equatable {
    let query: String?
    let generation: Int?
}

/// What the auto-refresh loop is keyed on.
private struct AutoRefreshKey: Equatable {
    let seconds: Int
    /// Whether the app is in front. Polling a thread nobody can see is the
    /// clearest waste of a radio there is.
    let isActive: Bool
    /// Whether this thread is the screen being read.
    let isVisible: Bool
}

/// The line between two posts in a thread.
///
/// `.separator` rather than a hand-mixed grey, so it tracks the system's own
/// hairline in both light and dark.
private struct PostSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
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
