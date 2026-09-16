import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

/// Builds posts without going through JSON, so a test can state exactly the
/// thread shape it is about.
private func makePost(
    _ num: Int,
    parent: Int = 100,
    comment: String = "",
    banned: Int = 0,
    closed: Bool = false,
    endless: Bool = false
) throws -> Post {
    let json = """
    {"num":\(num),"parent":\(parent),"board":"b","comment":"\(comment)",
     "banned":\(banned),"closed":\(closed ? 1 : 0),"endless":\(endless ? 1 : 0)}
    """
    return try JSONDecoder().decode(Post.self, from: Data(json.utf8))
}

@Suite("Thread merger")
struct ThreadMergerTests {
    // MARK: Full loads

    @Test("a full load replaces the whole post list")
    func fullLoadReplaces() throws {
        let existing = try [makePost(1, parent: 0), makePost(2)]
        let incoming = try [makePost(1, parent: 0), makePost(2), makePost(3)]

        let result = ThreadMerger.merge(existing: existing, incoming: incoming, mode: .full)
        #expect(result.posts.map(\.num) == [1, 2, 3])
        #expect(result.newPostNums == [3])
        #expect(result.deletedPostNums.isEmpty)
    }

    @Test("posts missing from a full load are reported as deleted")
    func fullLoadDetectsDeletions() throws {
        let existing = try [makePost(1, parent: 0), makePost(2), makePost(3)]
        let incoming = try [makePost(1, parent: 0), makePost(3)]

        let result = ThreadMerger.merge(existing: existing, incoming: incoming, mode: .full)
        #expect(result.deletedPostNums == [2])
        // The post is kept so the reader can still see what was replied to.
        #expect(result.posts.map(\.num) == [1, 2, 3])
    }

    @Test("deleted posts can be dropped instead of kept")
    func fullLoadCanDiscardDeletions() throws {
        let existing = try [makePost(1, parent: 0), makePost(2), makePost(3)]
        let incoming = try [makePost(1, parent: 0), makePost(3)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .full, keepDeletedPosts: false
        )
        #expect(result.posts.map(\.num) == [1, 3])
        #expect(result.deletedPostNums == [2])
    }

    @Test("an endless thread that trimmed its start is not treated as deleting posts")
    func endlessThreadTrims() throws {
        let existing = try [makePost(1, parent: 0, endless: true), makePost(2), makePost(3)]
        // The server dropped 2 from the head as the thread rolled over.
        let incoming = try [makePost(3), makePost(4)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .full, isEndless: true
        )
        #expect(result.deletedPostNums.isEmpty)
        #expect(result.trimmedPostNums == [1, 2])
        #expect(result.newPostNums == [4])
    }

    @Test("a full load on a first open reports every post as new")
    func firstLoad() throws {
        let incoming = try [makePost(1, parent: 0), makePost(2)]
        let result = ThreadMerger.merge(existing: [], incoming: incoming, mode: .full)
        #expect(result.newPostNums == [1, 2])
    }

    // MARK: Incremental loads

    @Test("an incremental load appends the posts after the anchor")
    func incrementalAppends() throws {
        let existing = try [makePost(1, parent: 0), makePost(2)]
        // The server echoes the anchor first.
        let incoming = try [makePost(2), makePost(3), makePost(4)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .incremental(anchor: 2)
        )
        #expect(result.posts.map(\.num) == [1, 2, 3, 4])
        #expect(result.newPostNums == [3, 4])
        #expect(result.needsFullReload == false)
    }

    @Test("the echoed anchor is not duplicated")
    func anchorIsNotDuplicated() throws {
        let existing = try [makePost(1, parent: 0), makePost(2)]
        let incoming = try [makePost(2)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .incremental(anchor: 2)
        )
        #expect(result.posts.count == 2)
        #expect(result.newPostNums.isEmpty)
    }

    @Test("an incremental reply that does not start at the anchor forces a full reload")
    func brokenAnchorForcesReload() throws {
        let existing = try [makePost(1, parent: 0), makePost(2)]
        // The thread rolled over: the anchor is gone.
        let incoming = try [makePost(7), makePost(8)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .incremental(anchor: 2)
        )
        #expect(result.needsFullReload)
    }

    @Test("an empty incremental reply forces a full reload")
    func emptyIncrementalForcesReload() throws {
        let existing = try [makePost(1, parent: 0)]
        let result = ThreadMerger.merge(
            existing: existing, incoming: [], mode: .incremental(anchor: 1)
        )
        #expect(result.needsFullReload)
    }

    @Test("an incremental load never reports deletions")
    func incrementalIgnoresDeletions() throws {
        let existing = try [makePost(1, parent: 0), makePost(2), makePost(3)]
        let incoming = try [makePost(3), makePost(4)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .incremental(anchor: 3)
        )
        #expect(result.deletedPostNums.isEmpty)
        #expect(result.posts.map(\.num) == [1, 2, 3, 4])
    }

    // MARK: Updates to existing posts

    @Test("a post that gained a ban marker is replaced, not duplicated")
    func bannedFlagUpdates() throws {
        let existing = try [makePost(1, parent: 0), makePost(2)]
        let incoming = try [makePost(2, banned: 1), makePost(3)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .incremental(anchor: 2)
        )
        #expect(result.posts.count == 3)
        #expect(result.posts.first { $0.num == 2 }?.isBanned == true)
        #expect(result.updatedPostNums == [2])
    }

    @Test("an unchanged post is not reported as updated")
    func unchangedPostIsNotAnUpdate() throws {
        let existing = try [makePost(1, parent: 0), makePost(2)]
        let incoming = try [makePost(2), makePost(3)]

        let result = ThreadMerger.merge(
            existing: existing, incoming: incoming, mode: .incremental(anchor: 2)
        )
        #expect(result.updatedPostNums.isEmpty)
    }

    // MARK: Ordering

    @Test("posts always come back in ascending number order")
    func resultIsOrdered() throws {
        let existing = try [makePost(3), makePost(1, parent: 0)]
        let incoming = try [makePost(2), makePost(1, parent: 0), makePost(3)]

        let result = ThreadMerger.merge(existing: existing, incoming: incoming, mode: .full)
        #expect(result.posts.map(\.num) == [1, 2, 3])
    }

    // MARK: Against the recorded thread

    @Test("the recorded thread and its follow-up merge into one ordered list")
    func mergesRecordedFixtures() throws {
        let thread = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let after = try FixtureLoader.decode(AfterResponse.self, from: .threadAfter)

        let result = ThreadMerger.merge(
            existing: thread.posts,
            incoming: after.posts,
            mode: .incremental(anchor: thread.maxNum)
        )
        #expect(result.needsFullReload == false)
        #expect(result.newPostNums.count == after.posts.count - 1)
        #expect(result.posts.count == thread.posts.count + result.newPostNums.count)
        #expect(result.posts.map(\.num) == result.posts.map(\.num).sorted())
    }

    @Test("an empty follow-up against the recorded thread adds nothing")
    func recordedEmptyAfter() throws {
        let thread = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let after = try FixtureLoader.decode(AfterResponse.self, from: .threadAfterEmpty)

        let result = ThreadMerger.merge(
            existing: thread.posts,
            incoming: after.posts,
            mode: .incremental(anchor: thread.maxNum)
        )
        #expect(result.newPostNums.isEmpty)
        #expect(result.needsFullReload == false)
    }
}
