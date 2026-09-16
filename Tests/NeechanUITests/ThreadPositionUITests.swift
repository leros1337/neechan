import XCTest

/// A thread reopens where it was left.
///
/// Threads here run to hundreds of posts, so landing at the top again means
/// scrolling the same ground twice to find the place.
@MainActor
final class ThreadPositionUITests: LiveUITestCase {
    func testAThreadReopensWhereItWasLeft() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let opened = try XCTUnwrap(topPostNumber(app), "no post number at the top of the thread")

        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 {
            scroll.swipeUp(velocity: .fast)
        }
        Thread.sleep(forTimeInterval: 1.5)

        let left = try XCTUnwrap(topPostNumber(app), "no post number after scrolling")
        XCTAssertNotEqual(left, opened, "the thread did not scroll, so there is nothing to remember")
        // What the reader could see when they left. The app remembers the post
        // at the very top edge, which may be the one only half on screen, so
        // landing on any of these is landing where they were.
        let wasOnScreen = visiblePostNumbers(app)

        XCTAssertTrue(leaveThread(app), "the tabs did not come back after the thread")
        reopenFromHistory(app)

        // The restore runs once the posts are laid out, which is a frame or two
        // after they appear.
        Thread.sleep(forTimeInterval: 3)

        let reopened = try XCTUnwrap(topPostNumber(app), "no post number after reopening")
        XCTAssertNotEqual(reopened, opened, "the thread reopened at the top, having forgotten the place")
        XCTAssertTrue(
            wasOnScreen.contains(reopened),
            "reopened on \(reopened), which was not on screen when the thread was left: \(wasOnScreen)"
        )
    }

    // MARK: Helpers

    /// The number of the topmost post actually on screen.
    ///
    /// Not `firstMatch`: the list keeps posts either side of the screen, so the
    /// first in the tree is usually one scrolled past.
    private func topPostNumber(_ app: XCUIApplication) -> String? {
        let window = app.windows.firstMatch.frame
        return app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\u{2116}"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY > window.minY + 100 && $0.frame.maxY < window.maxY }
            .min { $0.frame.minY < $1.frame.minY }?
            .label
    }

    /// Every post number on screen, top to bottom.
    private func visiblePostNumbers(_ app: XCUIApplication) -> [String] {
        let window = app.windows.firstMatch.frame
        return app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\u{2116}"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.maxY > window.minY && $0.frame.minY < window.maxY }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.label)
    }

    /// Opens the thread just read, which History has at the top.
    private func reopenFromHistory(_ app: XCUIApplication) {
        switchToTab(app, "History")
        let visited = app.staticTexts["/b/"].firstMatch
        XCTAssertTrue(visited.waitForExistence(timeout: 15), "the thread just read is not in history")
        visited.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the thread did not reopen from history"
        )
    }
}
