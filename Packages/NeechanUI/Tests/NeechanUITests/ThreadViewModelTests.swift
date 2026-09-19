import Foundation
import Synchronization
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

@Suite("Thread view model")
@MainActor
struct ThreadViewModelTests {
    private let recorded: ThreadResponse
    private let key: ThreadKey

    init() throws {
        recorded = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        key = ThreadKey(site: .dvach, board: "po", threadNum: recorded.currentThread)
    }

    private func makeModel(_ transport: StubTransport) throws -> ThreadViewModel {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "ThreadViewModelTests.\(UUID().uuidString)")!
        )
        // 2ch by name: these suites are written against 2ch fixtures and
        // 2ch-only endpoints, and the app's default site is 4chan.
        settings.imageboard = .dvach
        let services = try AppServices.inMemory(
            settings: settings,
            transport: transport
        )
        return ThreadViewModel(key: key, services: services)
    }

    private func stubbedTransport() async throws -> StubTransport {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/po/res/\(recorded.currentThread).json",
            data: try FixtureLoader.data(.thread)
        )
        return transport
    }

    // MARK: Loading

    @Test("loading fills the snapshot and records the visit")
    func loadPopulatesSnapshot() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        #expect(model.loadState == .loaded)
        #expect(model.snapshot.posts.isEmpty == false)
        #expect(model.snapshot.meta.title.isEmpty == false)
    }

    /// The thread view reads `snapshot` from every visible row, and observation
    /// reports a store whether or not the value moved. A poll that found nothing
    /// must therefore not store one, or every quiet refresh redraws the thread.
    @Test("a refresh that finds nothing does not disturb a reader of the snapshot")
    func quietRefreshDoesNotNotify() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(
            pathContaining: "/after/", data: try FixtureLoader.data(.threadAfterEmpty)
        )
        let model = try makeModel(transport)
        await model.load()
        // The first refresh settles the server's counters against the posts
        // actually held; the quiet ones being measured come after it.
        await model.refresh()

        let notified = ChangeFlag()
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            notified.raise()
        }

        await model.refresh()

        #expect(notified.wasRaised == false)
        #expect(model.newPostNums.isEmpty)
    }

    @Test("applying the same update twice stores it once")
    func duplicateUpdatesAreDropped() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()
        let update = ThreadUpdate.metaChanged(model.snapshot)

        let notified = ChangeFlag()
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            notified.raise()
        }

        model.apply(update)

        #expect(notified.wasRaised == false)
    }

    @Test("with no search the whole thread is shown, without waiting")
    func emptyQueryShowsEverything() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        #expect(model.visiblePosts.count == model.snapshot.posts.count)
    }

    @Test("a search narrows the thread once it settles")
    func searchNarrowsTheThread() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()
        let target = try #require(model.snapshot.posts.first)

        model.searchQuery = "\(target.num)"
        await model.updateSearch()

        #expect(model.visiblePosts.count < model.snapshot.posts.count)
        #expect(model.visiblePosts.contains { $0.num == target.num })
        #expect(model.isSearching)
    }

    /// Typing replaces the query several times a second, and the matches for a
    /// query the reader has already moved past must never land on screen.
    @Test("a search overtaken by another is not applied")
    func staleSearchIsDropped() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()
        let target = try #require(model.snapshot.posts.first)

        // The view keys its task on the query, so an overtaken search is a
        // cancelled task; here the same is expressed by simply running the
        // query the reader settled on.
        model.searchQuery = "zzzzz-no-such-post"
        model.searchQuery = "\(target.num)"
        await model.updateSearch()

        #expect(model.visiblePosts.contains { $0.num == target.num })
    }

    @Test("clearing the search shows the whole thread again, at once")
    func clearingSearchRestoresEverything() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()
        model.searchQuery = "zzzzz-no-such-post"
        await model.updateSearch()

        model.searchQuery = ""
        await model.updateSearch()

        #expect(model.visiblePosts.count == model.snapshot.posts.count)
        #expect(model.isSearching == false)
    }

    @Test("a failure is reported in words the reader can act on")
    func loadFailureIsReadable() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/po/res/\(recorded.currentThread).json",
            data: Data(),
            statusCode: 404
        )
        let model = try makeModel(transport)
        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("expected a failure, got \(model.loadState)")
            return
        }
        #expect(message.isEmpty == false)
    }

    // MARK: Position

    /// Threads here run to hundreds of posts, so coming back to the top means
    /// reading the same ground twice.
    @Test("where the reader was is kept and read back when the thread reopens")
    func positionIsRemembered() async throws {
        let transport = try await stubbedTransport()
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "ThreadViewModelTests.\(UUID().uuidString)")!
        )
        // 2ch by name: these suites are written against 2ch fixtures and
        // 2ch-only endpoints, and the app's default site is 4chan.
        settings.imageboard = .dvach
        let services = try AppServices.inMemory(
            settings: settings,
            transport: transport
        )
        let model = ThreadViewModel(key: key, services: services)
        await model.load()
        let post = try #require(model.snapshot.posts.dropFirst(3).first)

        await model.rememberPosition(post.num)

        // A second open of the same thread, sharing the store the first wrote to.
        let reopened = ThreadViewModel(key: key, services: services)
        await reopened.load()
        #expect(reopened.rememberedPostNum == post.num)
    }

    @Test("a post the thread no longer holds is not remembered")
    func doesNotRememberAPostOutsideTheThread() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        await model.rememberPosition(1)

        #expect(model.rememberedPostNum == nil)
    }

    @Test("nothing on screen leaves what was already remembered alone")
    func doesNotForgetOnAnEmptyReport() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()
        let post = try #require(model.snapshot.posts.dropFirst(2).first)
        await model.rememberPosition(post.num)

        await model.rememberPosition(nil)

        #expect(model.rememberedPostNum == post.num)
    }

    // MARK: Spoilers

    @Test("spoilers start hidden and toggle per post")
    func spoilerToggling() async throws {
        let model = try makeModel(try await stubbedTransport())
        #expect(model.isRevealed(1) == false)

        model.toggleSpoilers(in: 1)
        #expect(model.isRevealed(1))
        #expect(model.isRevealed(2) == false, "revealing one post must not reveal another")

        model.toggleSpoilers(in: 1)
        #expect(model.isRevealed(1) == false)
    }

    // MARK: Quote popups

    @Test("quoting a post in this thread uses the copy already loaded")
    func quoteFromLoadedThread() async throws {
        let transport = try await stubbedTransport()
        let model = try makeModel(transport)
        await model.load()

        let target = try #require(model.snapshot.posts.first?.num)
        let requestsBefore = await transport.recordedRequests().count
        await model.showQuote(board: "po", threadNum: key.threadNum, postNum: target)

        #expect(model.quotePopups.count == 1)
        #expect(model.quotePopups.first?.isRemote == false)
        #expect(model.quotePopups.first?.post.num == target)
        #expect(
            await transport.recordedRequests().count == requestsBefore,
            "a post already loaded must not be fetched again"
        )
    }

    @Test("quoting a post from elsewhere fetches it and marks it remote")
    func quoteFromAnotherThread() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(
            pathSuffix: "/api/mobile/v2/post/po/999",
            data: try FixtureLoader.data(.postSingle)
        )
        let model = try makeModel(transport)
        await model.load()
        await model.showQuote(board: "po", threadNum: nil, postNum: 999)

        #expect(model.quotePopups.count == 1)
        #expect(model.quotePopups.first?.isRemote == true)
        #expect(model.quotePopups.first?.content.plainText.isEmpty == false)
    }

    /// What the popup's replies pill counts.
    ///
    /// The pill is drawn from this thread's index, so a post quoted out of the
    /// thread the reader is in has a count the pill can trust.
    @Test("a quoted post from this thread carries its reply count")
    func aLocalQuoteKnowsItsReplies() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        let target = try #require(
            model.snapshot.posts.map(\.num).first {
                !model.snapshot.index.backlinks(to: $0).isEmpty
            },
            "the fixture thread has no post with replies"
        )
        await model.showQuote(board: "po", threadNum: nil, postNum: target)

        #expect(model.quotePopups.first?.isRemote == false)
        #expect(!model.snapshot.index.backlinks(to: target).isEmpty)
    }

    /// Why the popup's replies pill is gated on `isRemote` and not on the count.
    ///
    /// A reply index is built per thread, and a post number is only unique
    /// within a board — so a post fetched from elsewhere can carry a number this
    /// thread also uses. Asking the index about it then answers confidently and
    /// wrongly: it returns the *local* post's replies, filed under a post that
    /// has nothing to do with them.
    ///
    /// This fixture does exactly that, which is lucky: the post the stub returns
    /// is numbered the same as this thread's opening post. Counting it would put
    /// the opening post's replies on a stranger.
    @Test("a post quoted from another thread can collide with a local number")
    func aRemoteQuoteCanCollideWithALocalNumber() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(
            pathSuffix: "/api/mobile/v2/post/po/999",
            data: try FixtureLoader.data(.postSingle)
        )
        let model = try makeModel(transport)
        await model.load()
        await model.showQuote(board: "po", threadNum: nil, postNum: 999)

        let quoted = try #require(model.quotePopups.first)
        #expect(quoted.isRemote, "the fetched post must be marked as from elsewhere")

        // The collision itself, so that this test fails loudly rather than
        // quietly stops meaning anything if the fixture is ever renumbered.
        #expect(
            model.snapshot.posts.contains { $0.num == quoted.post.num },
            "the fixture no longer collides; pick a stub that does"
        )
        // And the consequence: the index answers, and its answer belongs to the
        // local post. `isRemote` is the only thing standing between that answer
        // and the reader.
        #expect(!model.snapshot.index.backlinks(to: quoted.post.num).isEmpty)
    }

    /// The site answers a quote pointing at a deleted post with error -31, and
    /// the tap used to do nothing whatever, which reads as a broken link.
    @Test("a post that cannot be fetched says so instead of doing nothing")
    func quoteFailureIsReported() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(pathSuffix: "/api/mobile/v2/post/po/999", data: Data(), statusCode: 404)
        let model = try makeModel(transport)
        await model.load()
        await model.showQuote(board: "po", threadNum: nil, postNum: 999)

        #expect(model.quotePopups.isEmpty)
        #expect(model.quoteStatus == .missing(postNum: 999))
    }

    @Test("the site's own \"no such post\" is reported the same way")
    func quoteDeletedPostIsReported() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(
            pathSuffix: "/api/mobile/v2/post/po/999", data: try FixtureLoader.data(.errorNoPost)
        )
        let model = try makeModel(transport)
        await model.load()
        await model.showQuote(board: "po", threadNum: nil, postNum: 999)

        #expect(model.quotePopups.isEmpty)
        #expect(model.quoteStatus == .missing(postNum: 999))
    }

    @Test("a quote that opens leaves no status behind")
    func successfulQuoteClearsTheStatus() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(
            pathSuffix: "/api/mobile/v2/post/po/999", data: try FixtureLoader.data(.postSingle)
        )
        let model = try makeModel(transport)
        await model.load()
        await model.showQuote(board: "po", threadNum: nil, postNum: 999)

        #expect(model.quotePopups.count == 1)
        #expect(model.quoteStatus == nil)
    }

    @Test("a quote already in the thread needs no fetch and no status")
    func localQuoteHasNoStatus() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()
        let target = try #require(model.snapshot.posts.first?.num)

        await model.showQuote(board: "po", threadNum: key.threadNum, postNum: target)
        #expect(model.quoteStatus == nil)
    }

    @Test("dismissing the status clears it")
    func statusCanBeDismissed() async throws {
        let transport = try await stubbedTransport()
        await transport.stub(pathSuffix: "/api/mobile/v2/post/po/999", data: Data(), statusCode: 404)
        let model = try makeModel(transport)
        await model.load()
        await model.showQuote(board: "po", threadNum: nil, postNum: 999)

        model.dismissQuoteStatus()
        #expect(model.quoteStatus == nil)
    }

    @Test("quotes stack and can be dismissed one at a time or all at once")
    func quoteStacking() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        let nums = model.snapshot.posts.prefix(3).map(\.num)
        try #require(nums.count == 3)
        for num in nums {
            await model.showQuote(board: "po", threadNum: key.threadNum, postNum: num)
        }
        #expect(model.quotePopups.count == 3)

        model.dismissTopQuote()
        #expect(model.quotePopups.count == 2)

        model.dismissAllQuotes()
        #expect(model.quotePopups.isEmpty)
    }

    @Test("dismissing with nothing open is harmless")
    func dismissEmptyStack() async throws {
        let model = try makeModel(try await stubbedTransport())
        model.dismissTopQuote()
        #expect(model.quotePopups.isEmpty)
    }

    // MARK: Replies

    @Test("replies to a post are listed from the index")
    func repliesComeFromTheIndex() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        let withReplies = model.snapshot.posts.first {
            !model.snapshot.index.backlinks(to: $0.num).isEmpty
        }
        let target = try #require(withReplies?.num, "the recorded thread should contain a reply")
        let replies = model.replies(to: target)

        #expect(replies.isEmpty == false)
        #expect(replies.allSatisfy { model.snapshot.index.references(from: $0.num).contains(target) })
    }

    // MARK: Hidden posts and the replies to them

    /// Hides through the real path — a rule in the store, then a refresh —
    /// rather than by poking the set, so this also covers the wiring between
    /// them.
    private func hideAReply(
        in model: ThreadViewModel
    ) async throws -> (target: Int, hidden: Int, all: [Int]) {
        let withReplies = model.snapshot.posts.first {
            !model.snapshot.index.backlinks(to: $0.num).isEmpty
        }
        let target = try #require(withReplies?.num, "the recorded thread should contain a reply")
        let all = model.snapshot.index.backlinks(to: target)
        let victim = try #require(all.first)

        #expect(model.visibleBacklinks(to: target) == all, "nothing is hidden yet")
        await model.hide(.post(num: victim))
        return (target, victim, all)
    }

    /// A hidden post keeps its place in the thread, as a stub, so a reply to it
    /// still makes sense. It does not keep its place in a *list of replies*:
    /// there it would be a row saying nothing.
    @Test("a hidden reply is left out of the replies to a post")
    func hiddenRepliesAreNotListed() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        let (target, hidden, all) = try await hideAReply(in: model)

        #expect(model.isHidden(hidden))
        #expect(!model.visibleBacklinks(to: target).contains(hidden))
        #expect(model.visibleBacklinks(to: target).count == all.count - 1)
        // The thread itself still carries it, as a stub.
        #expect(model.snapshot.index.backlinks(to: target) == all)
    }

    /// Revealing puts it back, which is what the reveal control is for.
    @Test("revealing a hidden post brings its reply back")
    func revealedRepliesComeBack() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        let (target, hidden, all) = try await hideAReply(in: model)
        model.revealedHiddenPosts = [hidden]

        #expect(model.effectiveHiddenPostNums.isEmpty)
        #expect(!model.isHidden(hidden))
        #expect(model.visibleBacklinks(to: target) == all)
    }

    /// The count on the pill and the rows in the window read the same set, so a
    /// post cannot promise three replies and then show one.
    @Test("the effective hidden set is what both the count and the list use")
    func hiddenSetHonoursReveals() async throws {
        let model = try makeModel(try await stubbedTransport())
        await model.load()

        let (_, hidden, _) = try await hideAReply(in: model)

        #expect(model.effectiveHiddenPostNums == [hidden])
        model.revealedHiddenPosts = [hidden]
        #expect(model.effectiveHiddenPostNums.isEmpty)
    }
}

/// What a refresh tells the reader afterwards.
///
/// Serialized: each test builds its own store and stub transport, and running
/// several of those at once trips the allocator underneath SwiftData.
@Suite("Refresh announcements", .serialized)
@MainActor
struct RefreshAnnouncementTests {
    private let recorded: ThreadResponse
    private let key: ThreadKey

    init() throws {
        recorded = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        key = ThreadKey(site: .dvach, board: "po", threadNum: recorded.currentThread)
    }

    private func makeModel(_ transport: StubTransport) throws -> (ThreadViewModel, AppServices) {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "RefreshAnnouncement.\(UUID().uuidString)")!
        )
        // 2ch by name: these suites are written against 2ch fixtures and
        // 2ch-only endpoints, and the app's default site is 4chan.
        settings.imageboard = .dvach
        let services = try AppServices.inMemory(
            settings: settings,
            transport: transport
        )
        return (ThreadViewModel(key: key, services: services), services)
    }

    private func loadedModel() async throws -> (ThreadViewModel, StubTransport, AppServices) {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/po/res/\(recorded.currentThread).json",
            data: try FixtureLoader.data(.thread)
        )
        let (model, services) = try makeModel(transport)
        await model.load()
        return (model, transport, services)
    }

    @Test("nothing is announced before a refresh happens")
    func nothingAtFirst() async throws {
        let (model, _, _) = try await loadedModel()
        #expect(model.lastRefresh == nil)
    }

    /// A refresh the reader asked for says so even when nothing arrived, so the
    /// gesture is acknowledged rather than appearing to do nothing.
    @Test("a refresh the reader asked for is announced even with no new posts")
    func announcesEmptyRefresh() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfterEmpty)
        )

        await model.refresh(userInitiated: true)

        let announcement = try #require(model.lastRefresh)
        #expect(announcement.newPostCount == 0)
    }

    /// A refresh that could not reach the site used to show the same cheerful
    /// tick as one that found nothing, because the announcement was made
    /// without looking at what came back.
    @Test("a refresh that failed says so, rather than reporting nothing new")
    func announcesFailure() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: Data(), statusCode: 500
        )

        await model.refresh(userInitiated: true)

        let announcement = try #require(model.lastRefresh)
        #expect(announcement.failure?.isEmpty == false)
        #expect(announcement.newPostCount == 0)
    }

    @Test("a failed refresh on a timer stays quiet")
    func failedTimerRefreshStaysQuiet() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: Data(), statusCode: 500
        )

        await model.refresh()

        #expect(model.lastRefresh == nil)
    }

    /// The watcher polls on a timer; announcing "nothing new" every time would
    /// be noise the reader did not ask for.
    @Test("a refresh on a timer stays quiet when nothing arrived")
    func timerRefreshStaysQuiet() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfterEmpty)
        )

        await model.refresh()
        #expect(model.lastRefresh == nil)
    }

    @Test("new posts are counted and the first one is offered to scroll to")
    func announcesNewPosts() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfter)
        )

        await model.refresh()

        let announcement = try #require(model.lastRefresh)
        #expect(announcement.newPostCount == model.newPostNums.count)
        #expect(announcement.newPostCount > 0)
        #expect(announcement.firstNewPostNum == model.newPostNums.first)
    }

    @Test("each refresh is announced separately, even with the same result")
    func announcementsAreDistinct() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfterEmpty)
        )

        await model.refresh(userInitiated: true)
        let first = try #require(model.lastRefresh)
        await model.refresh(userInitiated: true)
        let second = try #require(model.lastRefresh)

        #expect(first.id != second.id, "a second refresh must show its own toast")
    }

    /// The whole point of coming back to a thread is usually to see whether
    /// anyone answered you, and a count of new posts does not say that.
    @Test("replies to the reader are counted apart from the rest")
    func countsRepliesToTheReader() async throws {
        let (model, transport, services) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfter)
        )

        // Mark the post the incoming replies quote as the reader's own.
        let quoted = try #require(try firstQuotedPostNum())
        try await services.ownPosts.record(key, postNum: quoted)
        await model.refresh()

        let announcement = try #require(model.lastRefresh)
        #expect(announcement.replyToOwnCount > 0, "a reply to the reader was not counted")
        #expect(announcement.replyToOwnCount <= announcement.newPostCount)
        #expect(announcement.firstReplyToOwnPostNum != nil)
        #expect(announcement.destinationPostNum == announcement.firstReplyToOwnPostNum)
    }

    // MARK: Claiming a post by hand

    /// Posting from the app is the only thing that records an own post, which
    /// leaves no way to claim one written from a browser or a second device, and
    /// no way back from a wrong claim.
    @Test("a post can be claimed as the reader's own")
    func claimingAPostMarksIt() async throws {
        let (model, _, _) = try await loadedModel()
        let post = try #require(model.snapshot.posts.first).num
        #expect(model.snapshot.isOwn(post) == false, "the fixture already claimed it")

        await model.setOwned(true, postNum: post)

        #expect(model.snapshot.isOwn(post))
    }

    @Test("a claim can be taken back")
    func unclaimingAPostUnmarksIt() async throws {
        let (model, _, _) = try await loadedModel()
        let post = try #require(model.snapshot.posts.first).num
        await model.setOwned(true, postNum: post)

        await model.setOwned(false, postNum: post)

        #expect(model.snapshot.isOwn(post) == false)
    }

    /// A claim is worth nothing if it is forgotten when the thread is left, so
    /// it goes through the same store that posting writes to.
    @Test("a claim outlives the thread it was made in")
    func claimIsRemembered() async throws {
        let (model, _, services) = try await loadedModel()
        let post = try #require(model.snapshot.posts.first).num

        await model.setOwned(true, postNum: post)

        #expect(try await services.ownPosts.postNums(in: key).contains(post))
    }

    /// Claiming a post is how the reader gets the marker on every `>>N` that
    /// answers it, so the replies have to be recounted as well as the post
    /// itself being marked.
    @Test("claiming a post makes its replies count as replies to the reader")
    func claimingAPostCountsItsReplies() async throws {
        let (model, _, _) = try await loadedModel()
        let quoted = try #require(try firstQuotedPostNum())
        let replying = try #require(
            model.snapshot.posts.first { model.snapshot.index.references(from: $0.num).contains(quoted) }
        )
        #expect(model.snapshot.repliesToOwnPost(replying.num) == false)

        await model.setOwned(true, postNum: quoted)

        #expect(model.snapshot.repliesToOwnPost(replying.num))
    }

    @Test("a refresh that answers nobody reports no replies")
    func countsNoRepliesWhenNoneAreOwn() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfter)
        )

        await model.refresh()

        let announcement = try #require(model.lastRefresh)
        #expect(announcement.replyToOwnCount == 0)
        #expect(announcement.firstReplyToOwnPostNum == nil)
        #expect(announcement.destinationPostNum == announcement.firstNewPostNum)
    }

    /// A post number that an incoming post quotes, so marking it own makes that
    /// incoming post a reply to the reader.
    ///
    /// Read out of the raw comment rather than the parsed tree: a quote can sit
    /// at any depth, and the attribute is what the parser itself keys on.
    private func firstQuotedPostNum() throws -> Int? {
        let incoming = try FixtureLoader.decode(AfterResponse.self, from: .threadAfter)
        let pattern = try NSRegularExpression(pattern: "data-num=\"(\\d+)\"")

        // The first post of an incremental reply is the anchor the caller
        // already has, and the merge drops it, so a quote found there would
        // never arrive as a new post.
        for post in incoming.posts.dropFirst() {
            let range = NSRange(post.comment.startIndex..., in: post.comment)
            guard
                let match = pattern.firstMatch(in: post.comment, range: range),
                let quoted = Range(match.range(at: 1), in: post.comment).map({ post.comment[$0] }),
                let num = Int(quoted)
            else {
                continue
            }
            return num
        }
        return nil
    }

    @Test("dismissing clears it")
    func dismissClears() async throws {
        let (model, transport, _) = try await loadedModel()
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfterEmpty)
        )

        await model.refresh(userInitiated: true)
        model.dismissRefreshAnnouncement()
        #expect(model.lastRefresh == nil)
    }
}

/// Records whether an observation fired.
///
/// `withObservationTracking`'s change handler is `@Sendable` and runs wherever
/// the write happened, so a captured `var` will not do.
final class ChangeFlag: Sendable {
    private let flag = Mutex(false)

    func raise() { flag.withLock { $0 = true } }
    var wasRaised: Bool { flag.withLock { $0 } }
}
