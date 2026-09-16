import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import SwiftUI
import Testing
@testable import NeechanUI

/// Markup goes around what the reader picked.
///
/// The toolbar always had the code to wrap a selection, but nothing ever told
/// the view model what was selected: the editor was bound to the text alone, so
/// every style landed after the text instead of around it.
@Suite("Markup and selection", .serialized)
@MainActor
struct MarkupSelectionTests {
    private func makeModel() throws -> ReplyFormViewModel {
        let services = try AppServices.inMemory(
            settings: AppSettings(
                defaults: UserDefaults(suiteName: "markup.\(UUID().uuidString)")!
            ),
            transport: StubTransport()
        )
        return ReplyFormViewModel(board: "test", thread: 1, services: services)
    }

    /// Picks a stretch of the comment, the way the editor reports it.
    private func select(_ text: String, in model: ReplyFormViewModel) throws {
        let range = try #require(model.draft.comment.range(of: text))
        model.commentSelection = TextSelection(range: range)
    }

    private func selectedText(of model: ReplyFormViewModel) -> String? {
        guard let selection = model.commentSelection else { return nil }
        guard case .selection(let range) = selection.indices else { return nil }
        return String(model.draft.comment[range])
    }

    @Test("A style wraps the picked text")
    func wrapsSelection() throws {
        let model = try makeModel()
        model.draft.comment = "hello world"
        try select("world", in: model)

        model.applyMarkup(.bold)

        #expect(model.draft.comment == "hello **world**")
    }

    @Test("A style wraps text picked in the middle, leaving the rest alone")
    func wrapsSelectionInTheMiddle() throws {
        let model = try makeModel()
        model.draft.comment = "one two three"
        try select("two", in: model)

        model.applyMarkup(.spoiler)

        #expect(model.draft.comment == "one %%two%% three")
    }

    @Test("The picked text stays picked, so a second style nests around it")
    func keepsSelectionForTheNextStyle() throws {
        let model = try makeModel()
        model.draft.comment = "hello world"
        try select("world", in: model)

        model.applyMarkup(.bold)
        #expect(selectedText(of: model) == "world")

        model.applyMarkup(.italic)
        #expect(model.draft.comment == "hello ***world***")
    }

    /// Reaching for the toolbar can take focus off the field, and the editor
    /// clears its selection when that happens.
    @Test("A selection the editor has since dropped is still wrapped")
    func wrapsRememberedSelection() throws {
        let model = try makeModel()
        model.draft.comment = "hello world"
        try select("world", in: model)
        model.commentSelection = nil

        model.applyMarkup(.code)

        #expect(model.draft.comment == "hello [code]world[/code]")
    }

    @Test("With nothing picked the markers open at the cursor")
    func insertsAtTheCursor() throws {
        let model = try makeModel()
        model.draft.comment = "one two"
        let cursor = try #require(model.draft.comment.range(of: "one"))
        model.commentSelection = TextSelection(insertionPoint: cursor.upperBound)

        model.applyMarkup(.bold)

        #expect(model.draft.comment == "one**** two")
        // Between the markers, which is where the next thing typed belongs.
        guard case .selection(let range)? = model.commentSelection?.indices else {
            Issue.record("no selection")
            return
        }
        #expect(model.draft.comment.distance(from: model.draft.comment.startIndex, to: range.lowerBound) == 5)
        #expect(range.isEmpty)
    }

    @Test("With the field untouched the markers go on the end")
    func appendsWhenNothingWasEverPicked() throws {
        let model = try makeModel()
        model.draft.comment = "hello"

        model.applyMarkup(.underline)

        #expect(model.draft.comment == "hello____")
    }

    /// A remembered selection outlives the text it was made in, and an index
    /// past the end of the comment would trap rather than merely miss.
    @Test("A selection from longer text is dropped rather than used")
    func ignoresStaleSelection() throws {
        let model = try makeModel()
        model.draft.comment = "a long first draft"
        try select("first", in: model)
        model.draft.comment = "short"

        model.applyMarkup(.bold)

        #expect(model.draft.comment == "short****")
    }
}
