import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// Reading a post, or a whole thread, in the reader's own language.
@Suite("Translating a thread", .serialized)
@MainActor
struct ThreadTranslationTests {
    /// Stands in for the system's translator: marks every run it is given, so
    /// a test can see which ones went through it.
    private final class MarkingTranslator: PostTranslating {
        var failure: (any Error)?
        private(set) var calls: [[String]] = []

        func translate(_ texts: [String]) async throws -> [String] {
            calls.append(texts)
            if let failure { throw failure }
            return texts.map { "«\($0)»" }
        }
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "The languages are not supported." }
    }

    private let recorded: ThreadResponse
    private let key: ThreadKey
    private let english = Locale.Language(identifier: "en")

    init() throws {
        recorded = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        key = ThreadKey(site: .dvach, board: "po", threadNum: recorded.currentThread)
    }

    private func loadedModel() async throws -> (ThreadViewModel, StubTransport) {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/po/res/\(recorded.currentThread).json",
            data: try FixtureLoader.data(.thread)
        )
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "ThreadTranslationTests.\(UUID().uuidString)")!
        )
        settings.imageboard = .dvach
        let services = try AppServices.inMemory(settings: settings, transport: transport)
        let model = ThreadViewModel(key: key, services: services)
        await model.load()
        return (model, transport)
    }

    /// The posts with words in them, the ones a translation changes.
    private func postsWithText(_ model: ThreadViewModel) -> [Post] {
        model.snapshot.posts.filter { !model.snapshot.content(of: $0.num).translatableTexts.isEmpty }
    }

    @Test("one post is translated and the rest are left alone")
    func translatesOnePost() async throws {
        let (model, _) = try await loadedModel()
        let posts = postsWithText(model)
        let target = try #require(posts.first)
        let translator = MarkingTranslator()

        model.translate(target.num, into: english)
        #expect(model.isTranslating(target.num))
        #expect(model.translationConfiguration != nil, "the system's translator is asked to start")
        await model.translatePending(with: translator)

        let translated = try #require(model.translation(of: target.num))
        let original = model.snapshot.content(of: target.num)
        #expect(translated.translatableTexts == original.translatableTexts.map { "«\($0)»" })
        #expect(translated.references == original.references, "quotes still lead where they did")
        #expect(model.translation(of: posts[1].num) == nil)
        #expect(model.isTranslating(target.num) == false)
    }

    @Test("show original puts the post back")
    func showOriginal() async throws {
        let (model, _) = try await loadedModel()
        let target = try #require(postsWithText(model).first)
        model.translate(target.num, into: english)
        await model.translatePending(with: MarkingTranslator())

        model.showOriginal(target.num)

        #expect(model.translation(of: target.num) == nil)
    }

    @Test("a whole thread is translated, every post with words in it")
    func translatesTheThread() async throws {
        let (model, _) = try await loadedModel()

        model.translateThread(into: english)
        #expect(model.isThreadTranslated)
        await model.translatePending(with: MarkingTranslator())

        for post in postsWithText(model) {
            #expect(model.translation(of: post.num) != nil, "post \(post.num) was not translated")
        }

        model.showOriginalThread()
        #expect(model.isThreadTranslated == false)
        #expect(postsWithText(model).allSatisfy { model.translation(of: $0.num) == nil })
    }

    /// The reader asked for the thread in their language, not for the posts
    /// that happened to be there when they asked.
    @Test("posts that arrive in a translated thread are translated too")
    func arrivalsAreTranslated() async throws {
        let (model, transport) = try await loadedModel()
        model.translateThread(into: english)
        await model.translatePending(with: MarkingTranslator())
        let before = Set(model.snapshot.posts.map(\.num))
        await transport.stub(
            pathContaining: "/api/mobile/v2/after/", data: try FixtureLoader.data(.threadAfter)
        )

        await model.refresh()
        let arrived = postsWithText(model).filter { !before.contains($0.num) }
        try #require(!arrived.isEmpty, "the fixture should bring posts with words in them")
        await model.translatePending(with: MarkingTranslator())

        for post in arrived {
            #expect(model.translation(of: post.num) != nil, "post \(post.num) arrived untranslated")
        }
    }

    @Test("a translation that fails says why and leaves the post as it was")
    func failureIsReported() async throws {
        let (model, _) = try await loadedModel()
        let target = try #require(postsWithText(model).first)
        let translator = MarkingTranslator()
        translator.failure = Refused()

        model.translate(target.num, into: english)
        await model.translatePending(with: translator)

        #expect(model.translation(of: target.num) == nil)
        #expect(model.isTranslating(target.num) == false)
        #expect(model.notice == "The languages are not supported.")
    }

    /// The recorded thread is Russian. Asking for it in Russian is a request
    /// with nothing to do, and the system's translator refuses it with a
    /// message about unsupported pairs.
    @Test("a thread already in the reader's language is not sent off")
    func sameLanguageIsRefusedHere() async throws {
        let (model, _) = try await loadedModel()
        let target = try #require(postsWithText(model).first)

        model.translate(target.num, into: Locale.Language(identifier: "ru"))

        #expect(model.isTranslating(target.num) == false)
        #expect(model.translationConfiguration == nil)
        #expect(model.notice != nil)
    }
}
