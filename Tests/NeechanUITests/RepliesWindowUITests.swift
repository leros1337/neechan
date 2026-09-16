import XCTest

/// Opening a post's replies and getting back out of them.
///
/// A post shows only how many replies it has; tapping that count opens a window
/// listing them, each on its own card. These assert both halves: it opens with
/// content, and it closes by the button and by swiping down.
@MainActor
final class RepliesWindowUITests: LiveUITestCase {
    func testTheRepliesWindowListsEveryReply() throws {
        let app = XCUIApplication()
        let done = try openRepliesWindow(app)
        attach(app, name: "10-replies-window")

        // Each reply is its own card, so every one carries a post number.
        let replies = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "\u{2116}"))
            .count
        XCTAssertGreaterThan(replies, 0, "the replies window listed nothing")

        XCTAssertTrue(done.isHittable, "the replies window cannot be closed")
        done.tap()
        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 5),
            "closing the replies window did not dismiss it"
        )
    }

    func testANestedQuoteGoesBackRatherThanClosingTheWindow() throws {
        let app = XCUIApplication()
        let done = try openRepliesWindow(app)

        // A reply that quotes something opens that post on a pushed screen.
        guard tapFirstQuoteLink(in: app) else {
            throw XCTSkip("no reply in this window quoted a post in the same thread")
        }

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            back.waitForExistence(timeout: 10),
            "a nested quote should push a screen with a way back"
        )
        XCTAssertTrue(done.exists, "opening a nested quote closed the whole window")

        attach(app, name: "13-nested-reply")
        back.tap()

        // Back returns to the list rather than dismissing everything.
        XCTAssertTrue(done.waitForExistence(timeout: 5), "going back closed the window")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "replies"))
                .firstMatch.waitForExistence(timeout: 5),
            "going back did not return to the replies list"
        )
    }

    func testTheRepliesWindowCanBeSwipedAway() throws {
        let app = XCUIApplication()
        let done = try openRepliesWindow(app)

        // A sheet is dismissed by dragging it down.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            )

        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 5),
            "the replies window could not be swiped away"
        )
    }

    // MARK: Helpers

    /// Opens a thread with a conversation in it, taps a post's reply count and
    /// returns the window's close control once it is on screen.
    private func openRepliesWindow(_ app: XCUIApplication) throws -> XCUIElement {
        launchApp()
        openDefaultBoard(app)

        // A pinned thread with no replies has nothing to list, so a busy one is
        // chosen; even then not every post is replied to, hence the retry.
        for _ in 0..<3 {
            openThreadWithReplies(app, minimum: 30)
            if tapFirstReplyCount(in: app) {
                let done = app.buttons["Done"].firstMatch
                if done.waitForExistence(timeout: 15) { return done }
            }
            // Swipe back rather than reaching for a back button: the bar's
            // contents vary, and a swipe is what a reader would do anyway.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                )
            _ = replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout)
        }
        throw XCTSkip("no post with replies was visible in a thread right now")
    }

    /// Taps a post's reply count, scrolling until one is in reach.
    ///
    /// The `>>N` inside a post body is part of an attributed string rather than
    /// its own element, so the count is the only reliable way in.
    private func tapFirstReplyCount(in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            let counter = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "replies"))
                .firstMatch
            if counter.exists, counter.isHittable {
                counter.tap()
                return true
            }
            app.swipeUp()
        }
        return false
    }

    /// Taps a `>>N` inside a reply.
    ///
    /// Post references and ordinary web links are both rendered as links, so the
    /// label is matched: only a reference starts with the quote marker.
    private func tapFirstQuoteLink(in app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            let link = app.links
                .matching(NSPredicate(format: "label BEGINSWITH %@", ">>"))
                .firstMatch
            if link.exists, link.isHittable {
                link.tap()
                return true
            }
            app.swipeUp()
        }
        return false
    }
}
