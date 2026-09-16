import Foundation
import NeechanAPI
import NeechanCore
import Observation
import SwiftUI

/// Drives one open thread.
///
/// Owns the snapshot the view renders and the small pieces of view state that
/// outlive a redraw: which spoilers are revealed, which quote popups are
/// stacked, and where the reader was.
@MainActor
@Observable
public final class ThreadViewModel {
    public let key: ThreadKey

    public private(set) var snapshot: ThreadSnapshot
    public private(set) var loadState: LoadStatus = .idle
    /// Numbers of posts that arrived in the most recent refresh.
    public private(set) var newPostNums: [Int] = []

    /// What the most recent refresh found, for the thread to tell the reader.
    public private(set) var lastRefresh: RefreshAnnouncement?

    /// The result of one refresh.
    ///
    /// Carries an id so that two refreshes with the same result are two
    /// separate announcements rather than one that never changes.
    public struct RefreshAnnouncement: Identifiable, Equatable, Sendable {
        public let id = UUID()
        /// Why the refresh did not happen, when it did not.
        ///
        /// A refresh that failed used to report the same cheerful "No new
        /// posts" as one that found nothing, because the announcement was made
        /// without looking at what came back.
        public var failure: String?
        public let newPostCount: Int
        /// How many of those new posts answer something the reader wrote.
        public let replyToOwnCount: Int
        /// Where to scroll if the reader taps it: a reply to them when there is
        /// one, since that is what they came back for.
        public let firstNewPostNum: Int?
        public let firstReplyToOwnPostNum: Int?

        /// The post the toast jumps to.
        public var destinationPostNum: Int? {
            firstReplyToOwnPostNum ?? firstNewPostNum
        }
    }

    /// Posts whose spoilers the reader has revealed.
    public var revealedSpoilers: Set<Int> = []
    /// Stack of quoted posts shown as floating previews.
    public var quotePopups: [QuotedPost] = []

    /// What a `>>` tap is doing, when it is not simply showing the post.
    ///
    /// A quote can point at a post the thread does not hold: one that was
    /// deleted, or one from another thread. That has to be fetched, and the
    /// fetch can fail. Without this the tap did nothing at all, which reads as
    /// a broken link rather than as a missing post.
    public private(set) var quoteStatus: QuoteStatus?

    public enum QuoteStatus: Equatable, Sendable {
        case loading(postNum: Int)
        case missing(postNum: Int)
    }
    /// Post whose replies are listed in a sheet.
    public var repliesSheetPostNum: Int?
    /// Filters the thread to matching posts. Searching happens here rather than
    /// in the search tab, so the reader never leaves the thread to do it.
    public var searchQuery = ""
    /// Whether this thread is in the reader's favourites.
    public var isFavorite = false
    /// Posts hidden by a rule, and the rules hiding them.
    public private(set) var hiddenPostNums: Set<Int> = []
    /// Posts the reader chose to reveal despite a rule.
    public var revealedHiddenPosts: Set<Int> = []
    /// Where the "new posts" divider goes, if anywhere.
    public private(set) var firstUnreadPostNum: Int?

    /// The post the reader was last looking at, read back when the thread opens.
    ///
    /// Threads here run to hundreds of posts, so coming back to the top means
    /// scrolling the same ground again. Kept as a post number rather than an
    /// offset: the posts above it can change height, or be hidden by a rule,
    /// and a pixel offset would then land somewhere else entirely.
    public private(set) var rememberedPostNum: Int?

    public enum LoadStatus: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// A post shown in a floating preview above the thread.
    public struct QuotedPost: Identifiable, Sendable {
        public let id = UUID()
        public let post: Post
        public let content: PostContent
        /// True when the post is not in this thread and was fetched on demand.
        public let isRemote: Bool
    }

    private let repository: ThreadRepository
    private let services: AppServices

    public init(key: ThreadKey, services: AppServices) {
        self.key = key
        self.services = services
        self.repository = services.threadRepository(for: key)
        self.snapshot = .empty(key: key)
    }

    // MARK: Loading

    /// Whether this thread is being read from the copy on the device.
    public private(set) var isOffline = false
    /// Whether a copy of this thread is saved on the device.
    public private(set) var isSaved = false

    /// Loads the thread if it is not already held.
    public func start(offline: Bool = false) async {
        guard snapshot.isEmpty else { return }
        if offline {
            await loadSaved()
        } else {
            await load()
        }
    }

    /// Reads the copy on the device, so a saved thread opens with no network.
    public func loadSaved() async {
        loadState = .loading
        guard let response = try? await services.savedThreads.load(key) else {
            loadState = .failed(
                String(localized: "This thread is no longer saved on this device.", bundle: .neechanUI, locale: AppLocale.current)
            )
            return
        }
        isOffline = true
        isSaved = true
        snapshot = await repository.adopt(response)
        loadState = .loaded
        await loadOwnPosts()
        await refreshHiddenPosts()
    }

    /// Writes the thread to the device, with its thumbnails, so it can be read
    /// again with no network.
    public func save(includingFiles: Bool) async -> Bool {
        guard
            let (response, rawJSON) = try? await services.client.threadWithRawJSON(
                board: key.board, num: key.threadNum
            )
        else {
            return false
        }
        let saved = try? await services.savedThreads.save(
            response,
            rawJSON: rawJSON,
            key: key,
            domain: services.settings.domain,
            policy: includingFiles ? .fullFiles : .thumbnails,
            downloader: services.downloader
        )
        isSaved = saved != nil
        return isSaved
    }

    /// Whether the thread already has a copy on the device.
    public func refreshSavedState() async {
        isSaved = (try? await services.savedThreads.isSaved(key)) ?? false
    }

    /// Applies updates the repository publishes, including those caused by a
    /// refresh started elsewhere. Owned by the view's `task`, so it is cancelled
    /// when the thread closes.
    public func observeUpdates() async {
        for await update in await repository.updates {
            guard !Task.isCancelled else { return }
            apply(update)
        }
    }

    public func load() async {
        loadState = .loading
        do {
            snapshot = try await repository.load()
            loadState = .loaded
            await loadOwnPosts()
            await refreshFavoriteState()
            await refreshHiddenPosts()
            await refreshUnreadMarker()
            await loadRememberedPosition()
            await recordVisit()
        } catch {
            loadState = .failed(error.readableMessage)
        }
    }

    /// Fetches only what is new.
    ///
    /// - Parameter userInitiated: true when the reader pulled to refresh or
    ///   asked for it from the menu, which is announced either way. A refresh
    ///   on a timer announces itself only when something actually arrived.
    public func refresh(userInitiated: Bool = false) async {
        await loadOwnPosts()
        let update = await repository.refresh()
        apply(update)

        if case .failed(_, let error) = update {
            // Worth saying only when the reader asked: a timer that cannot
            // reach the site should not keep interrupting the thread.
            if userInitiated {
                lastRefresh = makeAnnouncement(failure: error.readableMessage)
            }
            return
        }
        if userInitiated || !newPostNums.isEmpty {
            lastRefresh = makeAnnouncement()
        }
    }

    /// Describes what the last refresh brought in.
    ///
    /// Replies to the reader are counted here rather than by the watcher, which
    /// only ever sees post counts from `/info` and cannot tell who answered whom.
    private func makeAnnouncement(failure: String? = nil) -> RefreshAnnouncement {
        let repliesToReader = newPostNums.filter(snapshot.repliesToOwnPost)
        return RefreshAnnouncement(
            failure: failure,
            newPostCount: newPostNums.count,
            replyToOwnCount: repliesToReader.count,
            firstNewPostNum: newPostNums.first,
            firstReplyToOwnPostNum: repliesToReader.first
        )
    }

    public func dismissRefreshAnnouncement() {
        lastRefresh = nil
    }

    public func dismissQuoteStatus() {
        quoteStatus = nil
    }

    /// Fetches the whole thread again.
    public func reload(userInitiated: Bool = false) async {
        apply(await repository.reloadFully())
        if userInitiated {
            lastRefresh = makeAnnouncement()
        }
    }

    private func apply(_ update: ThreadUpdate) {
        switch update {
        case .replaced(let snapshot):
            self.snapshot = snapshot
            newPostNums = []
            loadState = .loaded
        case .appended(let snapshot, let nums):
            self.snapshot = snapshot
            newPostNums = nums
            loadState = .loaded
        case .metaChanged(let snapshot):
            self.snapshot = snapshot
            if case .failed = loadState { loadState = .loaded }
        case .failed(let snapshot, let error):
            self.snapshot = snapshot
            loadState = snapshot.isEmpty ? .failed(error.readableMessage) : .loaded
        }
    }

    /// Marks the posts this device wrote, which 2ch does not report.
    public func loadOwnPosts() async {
        guard
            let nums = try? await services.ownPosts.postNums(
                board: key.board, threadNum: key.threadNum
            )
        else {
            return
        }
        await repository.setOwnPostNums(nums)
    }

    /// Recomputes which posts a rule hides.
    public func refreshHiddenPosts() async {
        let rules = (try? await services.hidden.rules()) ?? []
        let local = (try? await services.hidden.localRules(in: key)) ?? []
        hiddenPostNums = FilterEngine.hiddenPostNums(
            in: snapshot.posts,
            index: snapshot.index,
            thread: key,
            rules: rules,
            localRules: local
        )
    }

    public func refreshFavoriteState() async {
        isFavorite = (try? await services.favorites.isFavorite(key)) ?? false
    }

    /// Works out where the divider goes, from what the reader last read.
    public func refreshUnreadMarker() async {
        let state = try? await services.watchedThreads.state(for: key)
        let tracker = UnreadTracker(
            lastReadPostNum: state?.lastReadPostNum ?? 0,
            mode: services.settings.unreadMarkerMode
        )
        firstUnreadPostNum = tracker.firstUnreadPostNum(in: snapshot.posts.map(\.num))
    }

    /// Reads back where the reader left off.
    public func loadRememberedPosition() async {
        let state = try? await services.watchedThreads.state(for: key)
        rememberedPostNum = state?.scrollAnchorPostNum
    }

    /// Remembers the post at the top of the screen, so reopening lands there.
    ///
    /// A post that is no longer in the thread is not worth keeping: it would
    /// scroll to nothing and the reader would land at the top anyway.
    public func rememberPosition(_ postNum: Int?) async {
        guard let postNum, snapshot.post(num: postNum) != nil else { return }
        rememberedPostNum = postNum
        try? await services.watchedThreads.saveScrollAnchor(key, postNum: postNum)
    }

    /// Records that the reader has reached the end of the thread.
    public func markRead() async {
        guard let last = snapshot.posts.last?.num else { return }
        try? await services.watchedThreads.markRead(
            key, upTo: last, totalPosts: snapshot.posts.count
        )
    }

    public func toggleFavorite() async {
        let title = snapshot.meta.title.isEmpty
            ? snapshot.originalPost?.subject ?? "/\(key.board)/\(key.threadNum)"
            : snapshot.meta.title
        isFavorite = (try? await services.favorites.toggle(
            key,
            title: title,
            thumbnailPath: snapshot.originalPost?.files.first?.thumbnail
        )) ?? isFavorite
    }

    /// Hides posts by a rule made from one of them.
    public func hide(_ rule: LocalHideRule) async {
        try? await services.hidden.addLocalRule(rule, in: key)
        await refreshHiddenPosts()
    }

    public func revealAllHiddenPosts() async {
        try? await services.hidden.clearLocalRules(in: key)
        revealedHiddenPosts = []
        await refreshHiddenPosts()
    }

    private func recordVisit() async {
        // Counted whether or not history is being kept: the statistics are a
        // tally, not a list of what was read.
        services.settings.recordThreadOpened()

        let title = snapshot.meta.title.isEmpty
            ? snapshot.originalPost?.subject ?? "/\(key.board)/\(key.threadNum)"
            : snapshot.meta.title
        try? await services.history.recordVisit(
            key,
            title: title,
            thumbnailPath: snapshot.originalPost?.files.first?.thumbnail
        )
    }

    /// The posts to show, narrowed by the search when there is one.
    ///
    /// Hidden posts stay in the list as stubs rather than vanishing, so a reply
    /// to one still makes sense.
    public var visiblePosts: [Post] {
        snapshot.posts(matching: searchQuery)
    }

    public func isHidden(_ postNum: Int) -> Bool {
        hiddenPostNums.contains(postNum) && !revealedHiddenPosts.contains(postNum)
    }

    public func showsUnreadDivider(before postNum: Int) -> Bool {
        firstUnreadPostNum == postNum
    }

    public var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Interaction

    public func toggleSpoilers(in postNum: Int) {
        if revealedSpoilers.contains(postNum) {
            revealedSpoilers.remove(postNum)
        } else {
            revealedSpoilers.insert(postNum)
        }
    }

    public func isRevealed(_ postNum: Int) -> Bool {
        revealedSpoilers.contains(postNum)
    }

    /// Shows a quoted post as a floating preview, fetching it when it belongs to
    /// another thread.
    public func showQuote(board: String, threadNum: Int?, postNum: Int) async {
        quoteStatus = nil

        if let local = snapshot.post(num: postNum) {
            withAnimation(.snappy(duration: 0.2)) {
                quotePopups.append(
                    QuotedPost(post: local, content: snapshot.content(of: postNum), isRemote: false)
                )
            }
            return
        }

        // Fetching takes a moment on a slow connection, and a tap with nothing
        // on screen feels like nothing happened.
        quoteStatus = .loading(postNum: postNum)

        guard let response = try? await services.client.post(board: board, num: postNum),
              let post = response.post
        else {
            quoteStatus = .missing(postNum: postNum)
            return
        }
        quoteStatus = nil

        let content = CommentHTMLParser().parse(
            post.comment,
            inThread: threadNum ?? post.threadNum,
            onBoard: board
        )
        withAnimation(.snappy(duration: 0.2)) {
            quotePopups.append(QuotedPost(post: post, content: content, isRemote: true))
        }
    }

    public func dismissTopQuote() {
        if !quotePopups.isEmpty { quotePopups.removeLast() }
    }

    public func dismissAllQuotes() {
        quotePopups.removeAll()
    }

    /// Replies to a post, for the replies sheet.
    public func replies(to postNum: Int) -> [Post] {
        snapshot.index.backlinks(to: postNum).compactMap { snapshot.post(num: $0) }
    }
}
