import XCTest

/// The thread's controls: two small buttons in the corner, close to the bottom.
@MainActor
final class ThreadControlsUITests: LiveUITestCase {
    func testTheControlsAreCompactAndNearTheBottom() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let latest = app.buttons["Latest post"].firstMatch
        XCTAssertTrue(
            latest.waitForExistence(timeout: Self.networkTimeout),
            "the thread has no jump-to-latest control"
        )

        let screen = app.windows.firstMatch.frame
        let reply = app.buttons["Reply"].firstMatch
        let combined = reply.exists ? latest.frame.union(reply.frame) : latest.frame

        // Two buttons, not a bar: the system's bottom accessory always claims
        // the whole width the tab bar leaves, which this must not do.
        XCTAssertLessThan(
            combined.width, screen.width * 0.35,
            "the thread controls take too much of the width"
        )
        XCTAssertGreaterThan(
            combined.midY, screen.height * 0.85,
            "the thread controls sit too far from the bottom"
        )
        // With the tab bar gone they sit on the safe area itself. The old
        // layout left them a tab bar's height clear of it.
        XCTAssertLessThan(
            screen.maxY - combined.maxY, 60,
            "the thread controls are not as low as the screen allows"
        )

        attach(app, name: "17-thread-controls")

        latest.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: 10),
            "jumping to the latest post left the thread"
        )
    }

    /// A thread is read full screen: the tab bar only offers ways out of it,
    /// and while scrolling it shrinks to a pill in the corner that is easy to
    /// hit by accident.
    func testTheTabBarIsHiddenWhileReadingAThread() throws {
        let app = launchApp()
        openDefaultBoard(app)

        XCTAssertTrue(
            app.buttons["Boards"].firstMatch.exists,
            "the board list should still have its tabs"
        )

        openThreadWithReplies(app)
        XCTAssertTrue(
            app.buttons["Latest post"].firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the thread did not open"
        )

        XCTAssertTrue(
            waitForDisappearance(of: app.buttons["Boards"].firstMatch, timeout: 10),
            "the tab bar is still under the thread"
        )

        // And it comes back on the way out, or the reader is stranded.
        XCTAssertTrue(leaveThread(app), "the tab bar did not come back when the thread closed")
    }

    func testTheControlsAreGoneOutsideAThread() throws {
        let app = launchApp()
        openDefaultBoard(app)

        XCTAssertFalse(
            app.buttons["Latest post"].exists,
            "a board should not show the thread's controls"
        )
    }
}
