import Foundation
import NaturalLanguage
// The session is not marked Sendable, and its methods are not isolated to any
// actor, so Swift 6 refuses to hand it a request from the main actor at all.
// It is made and used on the main actor only, by SwiftUI and then here.
@preconcurrency import Translation

/// Turns runs of a post's words into the reader's language.
///
/// The thread's view model talks to this rather than to the system's session,
/// which SwiftUI alone can hand out, so a test can stand in for it.
@MainActor
protocol PostTranslating: AnyObject {
    /// The runs, translated, in the order they were given.
    func translate(_ texts: [String]) async throws -> [String]
}

/// The system's on-device translator, as the thread's `.translationTask` hands
/// it over.
@MainActor
final class SessionTranslator: PostTranslating {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let responses = try await session.translations(from: Self.requests(for: texts))
        // Matched by identifier rather than by position: nothing promises the
        // answers come back in the order they were asked.
        var translated = texts
        for response in responses {
            if let index = response.clientIdentifier.flatMap(Int.init), translated.indices.contains(index) {
                translated[index] = response.targetText
            }
        }
        return translated
    }

    /// Built apart from the main actor, so the batch is the translator's to
    /// take: made here, it counted as main-actor state and could not be sent.
    private nonisolated static func requests(for texts: [String]) -> sending [TranslationSession.Request] {
        texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
    }
}

enum ThreadLanguage {
    /// The language most of `texts` is written in, or nil when there is too
    /// little to tell.
    ///
    /// Decided once for the thread rather than per run: a run is often a word
    /// or two between a quote and a link, which no recogniser can place, and
    /// the system's translator refuses what it cannot place.
    static func detect(in texts: [String]) -> Locale.Language? {
        var sample = ""
        for text in texts where sample.count < 4000 {
            sample += text
            sample += "\n"
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Whether two languages are the same one, ignoring region and script.
    static func isSame(_ lhs: Locale.Language, as rhs: Locale.Language) -> Bool {
        guard let left = lhs.languageCode, let right = rhs.languageCode else { return false }
        return left == right
    }
}
