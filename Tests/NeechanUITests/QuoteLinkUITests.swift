import XCTest

/// Tapping a `>>123` inside a post body opens the post it points at.
///
/// This can only be tested here. The parser, the link scheme and the view model
/// are all unit-tested and were all correct while the feature was dead: the
/// body `Text` had text selection turned on, which makes SwiftUI swallow the
/// tap before the link is ever followed.
@MainActor
final class QuoteLinkUITests: LiveUITestCase {
    func testTappingAQuoteOpensTheQuotedPost() throws {
        let app = launchApp()
        openDefaultBoard(app)

        let link = try findQuoteLink(app)
        link.tap()

        XCTAssertTrue(
            quotePopupCloseButton(app).waitForExistence(timeout: Self.networkTimeout),
            "tapping a quote link did not open the quoted post"
        )
        attach(app, name: "18-quote-popup")
    }

    func testTheQuotedPostCloses() throws {
        let app = launchApp()
        openDefaultBoard(app)

        try findQuoteLink(app).tap()
        let close = quotePopupCloseButton(app)
        XCTAssertTrue(close.waitForExistence(timeout: Self.networkTimeout), "no popup to close")

        close.tap()
        XCTAssertTrue(
            waitForDisappearance(of: close, timeout: 10),
            "closing the quoted post left it on screen"
        )
        XCTAssertTrue(anyPostNumber(app).exists, "closing it left the thread behind too")
    }

    /// A quote inside an open quote opens another one.
    ///
    /// This is where it was broken: the handler that turns a `>>` into a popup
    /// was installed on the thread, and an overlay is a sibling of the view it
    /// decorates rather than a child, so nothing inside the popup ever reached
    /// it. Stacking is shown by the second control, "Close all".
    ///
    /// The chain is looked up from the site first rather than hunted for by
    /// tapping quotes at random: most quoted posts do not themselves quote
    /// anything, so a random walk skips far more often than it tests.
    func testAQuoteInsideAQuoteOpensAnother() throws {
        let chain = try XCTUnwrap(NestedQuoteChain.find(), "the board has no nested quote right now")
        let app = launchApp()

        goTo(app, board: chain.board, thread: chain.thread, post: chain.postA)

        let quote = app.links[">>\(chain.postB)"].firstMatch
        XCTAssertTrue(
            quote.waitForExistence(timeout: Self.networkTimeout),
            "the post that was supposed to quote №\(chain.postB) is not showing it"
        )
        quote.tap()

        let popup = app.descendants(matching: .any)
            .matching(identifier: "quote-popup")
            .firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: Self.networkTimeout), "the quote did not open")

        let nested = app.links[">>\(chain.postC)"].firstMatch
        XCTAssertTrue(
            nested.waitForExistence(timeout: 10),
            "the quoted post does not show the quote it contains"
        )
        nested.tap()

        XCTAssertTrue(
            app.buttons["Close all"].firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "a quote inside a quote opened nothing"
        )
        attach(app, name: "20-nested-quote")
    }

    /// A post's replies are reachable from the popup, not only from the thread.
    ///
    /// Deliberately not routed through `NestedQuoteChain`: that finds a quote
    /// whose target itself quotes something, which is rare enough that the test
    /// skipped every time it ran. All this needs is a quote whose target has
    /// replies — common on a busy thread — so it opens quotes in turn until it
    /// finds one, and gives up quietly if the thread has none.
    func testTheQuotedPostOffersItsReplies() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app, minimum: 30)

        let popup = app.descendants(matching: .any)
            .matching(identifier: "quote-popup")
            .firstMatch
        let pill = app.buttons["quote-popup-replies"].firstMatch

        for attempt in 0..<10 {
            // `matching`, not `containing`: the latter selects elements that
            // *hold* a match, which is not what a link's own label is.
            let quote = app.links
                .matching(NSPredicate(format: "label BEGINSWITH %@", ">>"))
                .firstMatch
            guard quote.waitForExistence(timeout: attempt == 0 ? Self.networkTimeout : 5),
                  quote.isHittable
            else {
                app.swipeUp()
                continue
            }
            quote.tap()
            guard popup.waitForExistence(timeout: 15) else {
                app.swipeUp()
                continue
            }

            if pill.waitForExistence(timeout: 3) { break }

            // This one's target has no replies of its own. Close and look on.
            app.buttons["Close"].firstMatch.tap()
            _ = waitForDisappearance(of: popup, timeout: 10)
            app.swipeUp()
        }

        try XCTSkipUnless(pill.exists, "no quoted post on this thread has replies right now")
        attach(app, name: "21-quote-replies-pill")

        pill.tap()
        XCTAssertTrue(
            app.buttons["Done"].firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the replies window did not open from the popup"
        )
        app.buttons["Done"].firstMatch.tap()

        // The point of a stack: the reader comes back to where they were.
        XCTAssertTrue(
            popup.waitForExistence(timeout: 10),
            "closing the replies window took the quote popup with it"
        )
    }

    /// Opens a thread at one post through the board list's "Go to" row, which
    /// resolves a pasted link.
    private func goTo(_ app: XCUIApplication, board: String, thread: Int, post: Int) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 10) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the board filter is missing")
        field.tap()
        field.typeText("https://2ch.org/\(board)/res/\(thread).html#\(post)")

        let goTo = app.descendants(matching: .any)
            .matching(identifier: "go-to")
            .firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 10), "the link did not resolve to anything")
        goTo.tap()

        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the thread did not open"
        )
    }

    // MARK: Helpers

    /// The popup's own close control. The quoted post is an overlay with Close,
    /// and Close all once more than one is stacked.
    private func quotePopupCloseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Close"].firstMatch
    }

    /// Finds a `>>123` in a post body, scrolling and trying other threads if the
    /// first one has none on screen.
    ///
    /// A quote is a link inside static text, so it is matched by its label
    /// rather than by an identifier of its own.
    private func findQuoteLink(_ app: XCUIApplication) throws -> XCUIElement {
        for _ in 0..<3 {
            openThreadWithReplies(app, minimum: 30)

            for _ in 0..<10 {
                let quote = app.links.containing(
                    NSPredicate(format: "label BEGINSWITH '>>'")
                ).firstMatch
                if quote.exists, quote.isHittable { return quote }

                let textQuote = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS '>>'")
                ).firstMatch
                if textQuote.exists, textQuote.isHittable { return textQuote }

                app.swipeUp()
            }
            goBackToBoard(app)
        }
        throw XCTSkip("no post quoting another was visible right now")
    }

    private func goBackToBoard(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            )
        _ = replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout)
    }
}
