import XCTest

/// Searching while reading a thread must search that thread, and must not take
/// the reader out of it.
@MainActor
final class ThreadSearchUITests: LiveUITestCase {
    /// Searching finds in the thread rather than filtering it: a query with no
    /// hits says so and leaves the posts where they were.
    func testSearchWithNoHitsSaysSoAndKeepsThePosts() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let field = try openSearch(app)
        field.typeText("щщzzzнеттакого")

        let count = app.staticTexts["search-match-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the search has no match bar")
        XCTAssertTrue(
            count.label.contains("No matches")
                || NSPredicate(format: "label CONTAINS 'No matches'").evaluate(with: count),
            "a query with no hits did not say so, it said \(count.label)"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "№"))
                .firstMatch.exists,
            "the thread was emptied instead of searched"
        )
    }

    /// The bar counts the matching posts and steps between them.
    func testSearchCountsMatchesAndStepsBetweenThem() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let field = try openSearch(app)
        field.typeText("а")

        let count = app.staticTexts["search-match-count"]
        let first = NSPredicate(format: "label BEGINSWITH '1 of '")
        expectation(for: first, evaluatedWith: count)
        waitForExpectations(timeout: 10)

        let total = Int(count.label.components(separatedBy: " of ").last ?? "") ?? 0
        attach(app, name: "12-thread-search")
        guard total > 1 else { return }

        app.buttons["search-next"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH '2 of '"), evaluatedWith: count)
        waitForExpectations(timeout: 5)

        app.buttons["search-previous"].tap()
        expectation(for: first, evaluatedWith: count)
        waitForExpectations(timeout: 5)
    }

    func testSearchingKeepsTheReaderInTheThread() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let field = try openSearch(app)
        field.typeText("а")

        // The thread's own navigation bar must still be there: searching is not
        // a separate screen, so the back gesture still leads to the board.
        XCTAssertTrue(
            app.navigationBars.firstMatch.exists,
            "searching pushed the reader out of the thread"
        )

        // Clearing the search restores the thread.
        if app.buttons["Cancel"].firstMatch.exists {
            app.buttons["Cancel"].firstMatch.tap()
        }
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "№"))
                .firstMatch.waitForExistence(timeout: 10),
            "the thread did not come back after searching"
        )
    }

    /// A thread whose every hit for "you" is in its first three posts, one of
    /// them long: counting posts made it "1 of 3", and stepping between three
    /// neighbours at the top of the thread looked like nothing happening.
    private static let youThread = "https://boards.4chan.org/3/thread/1011039"

    func testStepsThroughEveryOccurrenceInAThread() throws {
        let app = launchApp(extraArguments: ["-imageboard", "fourchan"], pinsImageboard: false)

        let goTo = app.searchFields.firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: Self.networkTimeout), "no board list")
        goTo.tap()
        goTo.typeText(Self.youThread)
        let go = app.buttons["go-to"].firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 10), "the link was not offered")
        go.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the thread did not load"
        )

        let field = try openSearch(app)
        field.typeText("you")

        let count = app.staticTexts["search-match-count"]
        expectation(for: NSPredicate(format: "label BEGINSWITH '1 of '"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        attach(app, name: "search-you-1")

        // Every hit, not every post: the three posts hold dozens between them.
        let total = Int(count.label.components(separatedBy: " of ").last ?? "") ?? 0
        print("TREE-BEGIN\n\(app.debugDescription)\nTREE-END")
        XCTAssertGreaterThan(total, 10, "the counter counted posts, not hits: \(count.label)")
        // A target a thumb can hit: the arrow used to be only its glyph.
        let next = app.buttons["search-next"]
        XCTAssertGreaterThanOrEqual(next.frame.height, 32, "the arrow is too small to press")

        for step in 2...4 {
            app.buttons["search-next"].tap()
            expectation(
                for: NSPredicate(format: "label BEGINSWITH %@", "\(step) of "),
                evaluatedWith: count
            )
            waitForExpectations(timeout: 5)
            // The arrows sit over the posts; a tap that fell through opened
            // whatever picture was under them.
            XCTAssertFalse(
                app.staticTexts["gallery-info"].exists,
                "pressing the arrow opened the file behind it"
            )
        }

        // Deep into the long post: its hit has to be scrolled to, not just
        // counted. The highlighted body must still be on screen.
        for _ in 5...12 { app.buttons["search-next"].tap() }
        expectation(for: NSPredicate(format: "label BEGINSWITH '12 of '"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        attach(app, name: "search-you-12")

        app.buttons["search-previous"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH '11 of '"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
    }

    /// Reveals the thread's search field through the menu, which is the way a
    /// reader finds it: the field itself sits above the content until pulled
    /// down.
    private func openSearch(_ app: XCUIApplication) throws -> XCUIElement {
        let menu = app.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "the thread has no actions menu")
        menu.tap()

        let action = app.buttons["Search in thread"].firstMatch
        XCTAssertTrue(
            action.waitForExistence(timeout: 10),
            "the menu does not offer searching the thread"
        )
        action.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 10),
            "a thread should offer a search field of its own"
        )
        if !field.value.debugDescription.isEmpty {
            field.tap()
        }
        return field
    }

}
