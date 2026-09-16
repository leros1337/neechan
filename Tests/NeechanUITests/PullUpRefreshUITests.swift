import XCTest

/// Pulling up past the end of a thread refreshes it.
@MainActor
final class PullUpRefreshUITests: LiveUITestCase {
    /// Holding the drag past the threshold shows the indicator, which is the
    /// only moment it exists: releasing starts the refresh and it goes away.
    func testPullingUpPastTheEndRefreshes() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        scrollToBottom(app)

        let scroll = app.scrollViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))

        // Released rather than held: the accessibility tree is not refreshed
        // while a finger is down, so the indicator is checked for during the
        // refresh the release starts.
        start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        let indicator = app.descendants(matching: .any)
            .matching(identifier: "pull-up-refresh")
            .firstMatch
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 5),
            "pulling up past the end did not start a refresh"
        )
    }

    /// The thread survives the gesture and still shows its posts afterwards.
    func testThreadStillReadsAfterAPullUp() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        scrollToBottom(app)
        let scroll = app.scrollViews.firstMatch
        scroll.swipeUp(velocity: .fast)
        scroll.swipeUp(velocity: .fast)

        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the thread lost its posts after a pull up"
        )
    }

    /// Puts the reader at the end of the thread.
    ///
    /// Swiping there by hand is unreliable: a busy thread is thousands of
    /// points long and loads lazily, so the thread's own "latest post" control
    /// is used instead.
    private func scrollToBottom(_ app: XCUIApplication) {
        let latest = app.buttons["Latest post"]
        XCTAssertTrue(latest.waitForExistence(timeout: 10), "the latest post button is missing")
        latest.tap()
        // The scroll is animated; the drag has to start once it has settled.
        Thread.sleep(forTimeInterval: 1.5)
    }
}
