import XCTest

/// Boards that give posters a country flag and a generated nickname, which the
/// app used to show as raw HTML or not at all.
@MainActor
final class PoliticsBoardUITests: LiveUITestCase {
    func testFlagsAndPosterNamesRender() throws {
        let app = launchApp()
        openBoard(app, "/po/")

        let replies = replyCounts(app).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: Self.networkTimeout))
        replies.tap()
        XCTAssertTrue(anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout))

        // No post header should still be showing markup or escapes.
        let headers = app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label)
        XCTAssertFalse(
            headers.contains { $0.contains("<span") || $0.contains("&nbsp;") || $0.contains("&gt;") },
            "a header still shows raw HTML: \(headers.filter { $0.contains("<") || $0.contains("&") })"
        )

        // /po/ tags every poster with a country flag.
        let flags = headers.filter { $0.unicodeScalars.contains { scalar in
            (0x1F1E6...0x1F1FF).contains(Int(scalar.value))
        } }
        XCTAssertFalse(flags.isEmpty, "no country flag was drawn on /po/")
    }

    /// A subject with a quote in it used to read "&gt;" instead of ">".
    func testSubjectsAreNotEscaped() throws {
        let app = launchApp()
        openBoard(app, "/po/")

        let subjects = app.cells.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label)
        XCTAssertFalse(subjects.isEmpty, "the board showed nothing")
        XCTAssertFalse(
            subjects.contains { $0.contains("&gt;") || $0.contains("&amp;") || $0.contains("&nbsp;") },
            "a subject still shows an HTML escape"
        )
    }

    /// Opens a board by filtering the directory for it.
    ///
    /// The list is long and /po/ is far down it, so scrolling to find it is
    /// neither quick nor reliable.
    private func openBoard(_ app: XCUIApplication, _ code: String) {
        XCTAssertTrue(
            app.staticTexts["/b/"].waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )

        // The filter is tucked above the list, so it may need pulling into view.
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) {
            app.swipeDown()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the board filter is missing")
        field.tap()
        field.typeText(code.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        // The filter shows the board both as a row and as a "Go to" suggestion.
        let board = app.cells.staticTexts[code].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 10), "\(code) is not listed")
        board.tap()
        useCardsLayout(app)
    }
}
