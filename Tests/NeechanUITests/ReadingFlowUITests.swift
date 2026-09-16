import XCTest

/// Walks the reading path against the live site: boards, a thread list, a
/// thread. These are the milestone's acceptance checks, so they assert that
/// real content arrived rather than only that a screen appeared.
@MainActor
final class ReadingFlowUITests: LiveUITestCase {
    /// Opens the first board in the directory and returns once threads render.
    ///
    /// The list only instantiates rows that are on screen, so a test must not
    /// reach for a board by name unless it scrolls to it first.
    private func openFirstBoard(_ app: XCUIApplication) {
        let firstBoard = app.staticTexts["/b/"]
        XCTAssertTrue(firstBoard.waitForExistence(timeout: 30), "board list did not load")
        firstBoard.tap()

        // A thread row always shows a reply count, so the bubble icon appearing
        // means threads decoded and rendered.
        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "threads did not load"
        )
    }

    func testBoardsLoadFromTheLiveSite() throws {
        let app = launchApp()

        let boardRow = app.staticTexts["/b/"]
        XCTAssertTrue(
            boardRow.waitForExistence(timeout: 30),
            "the board list should load from the live site"
        )
        attachScreenshot(app, name: "01-boards")
    }

    func testOpeningABoardShowsThreads() throws {
        let app = launchApp()
        openFirstBoard(app)
        attachScreenshot(app, name: "02-threads")
    }

    func testOpeningAThreadShowsPosts() throws {
        let app = launchApp()
        openFirstBoard(app)
        openThreadWithReplies(app)
        attachScreenshot(app, name: "03-thread")
    }

    func testHistoryRecordsAVisitedThread() throws {
        let app = launchApp()
        openFirstBoard(app)
        openThreadWithReplies(app)

        XCTAssertTrue(leaveThread(app), "the tabs did not come back after the thread")
        app.buttons["History"].tap()
        XCTAssertTrue(
            app.staticTexts["/b/"].waitForExistence(timeout: 15),
            "the visited thread should appear in history"
        )
        attachScreenshot(app, name: "04-history")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
