import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

/// Hiding a thread, which had no tests at all while it silently did nothing.
@Suite("Hidden threads", .serialized)
struct HiddenThreadTests {
    private func makeRepository() throws -> HiddenContentRepository {
        HiddenContentRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 123)

    @Test("a hidden thread is listed as hidden on its board")
    func hideAndList() async throws {
        let repository = try makeRepository()
        try await repository.hideThread(key, title: "Тред")

        #expect(try await repository.hiddenThreadNums(on: BoardRef(site: .dvach, code: "b")) == [123])
        #expect(try await repository.hiddenThreadNums(on: BoardRef(site: .dvach, code: "po")).isEmpty)
    }

    @Test("hiding the same thread twice does not duplicate it")
    func hideIsIdempotent() async throws {
        let repository = try makeRepository()
        try await repository.hideThread(key, title: "Тред")
        try await repository.hideThread(key, title: "Тред")

        #expect(try await repository.hiddenThreads(site: .dvach).count == 1)
    }

    @Test("unhiding brings it back")
    func unhide() async throws {
        let repository = try makeRepository()
        try await repository.hideThread(key, title: "Тред")
        try await repository.unhideThread(key)

        #expect(try await repository.hiddenThreadNums(on: BoardRef(site: .dvach, code: "b")).isEmpty)
        #expect(try await repository.hiddenThreads(site: .dvach).isEmpty)
    }

    @Test("the list carries what is needed to show and undo it, newest first")
    func listContents() async throws {
        let repository = try makeRepository()
        try await repository.hideThread(ThreadKey(site: .dvach, board: "b", threadNum: 1), title: "Первый")
        try await repository.hideThread(ThreadKey(site: .dvach, board: "po", threadNum: 2), title: "Второй")

        let items = try await repository.hiddenThreads(site: .dvach)
        #expect(items.count == 2)
        #expect(items.first?.title == "Второй", "the most recently hidden comes first")
        #expect(items.first?.key.board == "po")
        #expect(items.allSatisfy { $0.hiddenAt <= .now })
    }

    @Test("everything can be brought back at once")
    func unhideAll() async throws {
        let repository = try makeRepository()
        try await repository.hideThread(ThreadKey(site: .dvach, board: "b", threadNum: 1), title: "Один")
        try await repository.hideThread(ThreadKey(site: .dvach, board: "po", threadNum: 2), title: "Два")

        try await repository.unhideAllThreads(site: .dvach)
        #expect(try await repository.hiddenThreads(site: .dvach).isEmpty)
    }
}

/// Rules that hide a whole thread from the board list.
///
/// A rule marked "opening post only" matched nothing there, because the board
/// list never consulted the rules at all.
@Suite("Autohide on a board")
struct BoardAutohideTests {
    /// An opening post, decoded the way the site sends one.
    private func opening(subject: String = "", comment: String = "", name: String = "") throws -> Post {
        let object: [String: Any] = [
            "num": 10, "parent": 0, "board": "b",
            "subject": subject, "comment": comment, "name": name,
        ]
        return try JSONDecoder().decode(
            Post.self, from: try JSONSerialization.data(withJSONObject: object)
        )
    }

    @Test("a rule matching the opening post hides the thread")
    func hidesMatchingThread() throws {
        let rule = AutohideRuleValue(pattern: "политика", matchesSubject: true)

        #expect(
            FilterEngine.hidesThread(
                openingPost: try opening(subject: "Тред про политика"),
                onBoard: BoardRef(site: .dvach, code: "b"),
                rules: [rule]
            )
        )
    }

    @Test("a thread nothing matches stays")
    func keepsOtherThreads() throws {
        let rule = AutohideRuleValue(pattern: "политика", matchesSubject: true)

        #expect(
            FilterEngine.hidesThread(
                openingPost: try opening(subject: "Тред про котов"),
                onBoard: BoardRef(site: .dvach, code: "b"),
                rules: [rule]
            ) == false
        )
    }

    @Test("a rule for another board does not reach this one")
    func respectsBoardScope() throws {
        let rule = AutohideRuleValue(pattern: "кот", matchesSubject: true, boards: ["po"])

        #expect(
            FilterEngine.hidesThread(
                openingPost: try opening(subject: "кот"),
                onBoard: BoardRef(site: .dvach, code: "b"),
                rules: [rule]
            ) == false
        )
    }

    /// The flag exists so a rule can hide threads without hiding every reply
    /// that quotes them; on a board list every post is an opening post.
    @Test("an opening-post-only rule applies here")
    func openingPostOnlyApplies() throws {
        let rule = AutohideRuleValue(
            pattern: "кот",
            matchesSubject: true,
            appliesToOriginalPostOnly: true
        )

        #expect(
            FilterEngine.hidesThread(
                openingPost: try opening(subject: "кот"),
                onBoard: BoardRef(site: .dvach, code: "b"),
                rules: [rule]
            )
        )
    }

    @Test("a disabled rule hides nothing")
    func disabledRuleIsInert() throws {
        var rule = AutohideRuleValue(pattern: "кот", matchesSubject: true)
        rule.isEnabled = false

        #expect(
            FilterEngine.hidesThread(openingPost: try opening(subject: "кот"), onBoard: BoardRef(site: .dvach, code: "b"), rules: [rule])
                == false
        )
    }

    @Test("with no rules at all nothing is hidden")
    func noRules() throws {
        #expect(
            FilterEngine.hidesThread(openingPost: try opening(subject: "кот"), onBoard: BoardRef(site: .dvach, code: "b"), rules: [])
                == false
        )
    }
}
