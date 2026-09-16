import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

private func post(_ num: Int, replyingTo targets: [Int] = [], inThread thread: Int = 100) throws -> Post {
    let links = targets.map {
        #"<a class=\"post-reply-link\" data-thread=\"\#(thread)\" data-num=\"\#($0)\">&gt;&gt;\#($0)</a>"#
    }.joined(separator: "<br>")
    let json = """
    {"num":\(num),"parent":\(num == thread ? 0 : thread),"board":"b","comment":"\(links)"}
    """
    return try JSONDecoder().decode(Post.self, from: Data(json.utf8))
}

@Suite("Reply index")
struct ReplyIndexTests {
    private let thread = ThreadKey(board: "b", threadNum: 100)

    @Test("a reply registers a backlink on its target")
    func buildsBacklinks() throws {
        let posts = try [post(100), post(101, replyingTo: [100]), post(102, replyingTo: [100])]
        let index = ReplyIndex(posts: posts, thread: thread)

        #expect(index.backlinks(to: 100) == [101, 102])
        #expect(index.backlinks(to: 101).isEmpty)
    }

    @Test("the index records what each post replies to")
    func recordsOutgoingReferences() throws {
        let posts = try [post(100), post(101, replyingTo: [100]), post(102, replyingTo: [100, 101])]
        let index = ReplyIndex(posts: posts, thread: thread)

        #expect(index.references(from: 102) == [100, 101])
        #expect(index.references(from: 100).isEmpty)
    }

    @Test("a reference into another thread is not a backlink here")
    func ignoresCrossThreadReferences() throws {
        let posts = try [post(100), post(101, replyingTo: [999], inThread: 777)]
        let index = ReplyIndex(posts: posts, thread: thread)

        #expect(index.backlinks(to: 999).isEmpty)
        #expect(index.references(from: 101).isEmpty)
    }

    @Test("a post referencing itself is ignored")
    func ignoresSelfReference() throws {
        let posts = try [post(100), post(101, replyingTo: [101])]
        let index = ReplyIndex(posts: posts, thread: thread)
        #expect(index.backlinks(to: 101).isEmpty)
    }

    @Test("duplicate references count once")
    func deduplicatesReferences() throws {
        let posts = try [post(100), post(101, replyingTo: [100, 100, 100])]
        let index = ReplyIndex(posts: posts, thread: thread)
        #expect(index.backlinks(to: 100) == [101])
        #expect(index.references(from: 101) == [100])
    }

    @Test("appending posts extends the index without rebuilding it")
    func appendsIncrementally() throws {
        var index = ReplyIndex(posts: try [post(100), post(101, replyingTo: [100])], thread: thread)
        index.append(try [post(102, replyingTo: [100, 101])])

        #expect(index.backlinks(to: 100) == [101, 102])
        #expect(index.backlinks(to: 101) == [102])
    }

    @Test("backlinks stay in post order")
    func backlinksAreOrdered() throws {
        var index = ReplyIndex(posts: try [post(100)], thread: thread)
        index.append(try [post(105, replyingTo: [100])])
        index.append(try [post(102, replyingTo: [100])])
        // Insertion order is the order the posts arrived, which is the order the
        // reader saw them.
        #expect(index.backlinks(to: 100) == [105, 102])
    }

    @Test("parsed comment bodies are cached for reuse by the view")
    func cachesParsedContent() throws {
        let posts = try [post(100), post(101, replyingTo: [100])]
        let index = ReplyIndex(posts: posts, thread: thread)
        let content = try #require(index.content(of: 101))
        #expect(content.plainText == ">>100")
        #expect(content.references.count == 1)
    }

    @Test("the whole recorded thread indexes and finds real backlinks")
    func indexesRecordedThread() throws {
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let key = ThreadKey(board: "po", threadNum: response.currentThread)
        let index = ReplyIndex(posts: response.posts, thread: key)

        let linked = response.posts.filter { !index.references(from: $0.num).isEmpty }
        #expect(linked.isEmpty == false, "the recorded thread should contain reply links")

        // Every backlink must point at a post that exists in the thread.
        let nums = Set(response.posts.map(\.num))
        for post in response.posts {
            for target in index.references(from: post.num) where nums.contains(target) {
                #expect(index.backlinks(to: target).contains(post.num))
            }
        }
    }
}

@Suite("Searching within a thread")
struct ThreadSearchTests {
    private func snapshot() throws -> ThreadSnapshot {
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let key = ThreadKey(board: "po", threadNum: response.currentThread)
        return ThreadSnapshot(
            key: key,
            posts: response.posts,
            meta: ThreadMeta(response: response),
            index: ReplyIndex(posts: response.posts, thread: key)
        )
    }

    @Test("an empty query returns the whole thread")
    func emptyQueryReturnsEverything() throws {
        let snapshot = try snapshot()
        #expect(snapshot.posts(matching: "").count == snapshot.posts.count)
        #expect(snapshot.posts(matching: "   ").count == snapshot.posts.count)
    }

    @Test("a word from a post's text finds that post")
    func findsByText() throws {
        let snapshot = try snapshot()
        let target = try #require(snapshot.posts.first { snapshot.content(of: $0.num).plainText.count > 40 })
        let word = try #require(
            snapshot.content(of: target.num).plainText
                .split(whereSeparator: \.isWhitespace)
                .first { $0.count >= 6 }
        )

        let hits = snapshot.posts(matching: String(word))
        #expect(hits.contains { $0.num == target.num })
        #expect(hits.count < snapshot.posts.count || snapshot.posts.count == 1)
    }

    @Test("the search ignores markup, matching only what is shown")
    func ignoresMarkup() throws {
        let snapshot = try snapshot()
        // Every recorded comment is HTML, so a tag name must not match.
        #expect(snapshot.posts(matching: "unkfunc").isEmpty)
        #expect(snapshot.posts(matching: "post-reply-link").isEmpty)
    }

    @Test("a post number finds that post")
    func findsByNumber() throws {
        let snapshot = try snapshot()
        let target = try #require(snapshot.posts.last?.num)
        #expect(snapshot.posts(matching: String(target)).contains { $0.num == target })
    }

    @Test("the search is case-insensitive")
    func caseInsensitive() throws {
        let snapshot = try snapshot()
        let word = try #require(
            snapshot.posts
                .lazy
                .flatMap { snapshot.content(of: $0.num).plainText.split(whereSeparator: \.isWhitespace) }
                .first { $0.count >= 6 && $0.contains(where: \.isLowercase) }
        )
        #expect(
            snapshot.posts(matching: String(word).uppercased()).isEmpty == false,
            "an uppercase query should still match lowercase text"
        )
    }

    @Test("a query that matches nothing returns nothing")
    func noMatches() throws {
        #expect(try snapshot().posts(matching: "щщzzzнеттакого").isEmpty)
    }

    @Test("results keep the thread's own order")
    func preservesOrder() throws {
        let snapshot = try snapshot()
        let hits = snapshot.posts(matching: "о")
        #expect(hits.map(\.num) == hits.map(\.num).sorted())
    }
}

@Suite("Post position in a thread")
struct ThreadPositionTests {
    private func snapshot() throws -> ThreadSnapshot {
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let key = ThreadKey(board: "po", threadNum: response.currentThread)
        return ThreadSnapshot(
            key: key,
            posts: response.posts,
            meta: ThreadMeta(response: response),
            index: ReplyIndex(posts: response.posts, thread: key)
        )
    }

    @Test("the opening post is the first")
    func openingPostIsOne() throws {
        let snapshot = try snapshot()
        let op = try #require(snapshot.posts.first)
        #expect(snapshot.indexInThread(of: op) == 1)
    }

    @Test("positions count up with the thread, without gaps")
    func positionsAreSequential() throws {
        let snapshot = try snapshot()
        let positions = snapshot.posts.compactMap { snapshot.indexInThread(of: $0) }
        #expect(positions == Array(1...snapshot.posts.count))
    }

    @Test("a post the server numbered keeps that number")
    func serverNumberWins() throws {
        // A post fetched on its own has no place in the list, but the server
        // told us where it belongs.
        let json = Data(#"{"num":5,"parent":1,"number":42}"#.utf8)
        let post = try JSONDecoder().decode(Post.self, from: json)
        let snapshot = try snapshot()
        #expect(snapshot.indexInThread(of: post) == 42)
    }

    @Test("a post from nowhere has no position rather than a wrong one")
    func unknownPostHasNoPosition() throws {
        let json = Data(#"{"num":999999999,"parent":1}"#.utf8)
        let post = try JSONDecoder().decode(Post.self, from: json)
        #expect(try snapshot().indexInThread(of: post) == nil)
    }
}
