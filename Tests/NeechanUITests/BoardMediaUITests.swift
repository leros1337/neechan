import XCTest

/// On a board, the thumbnail and the text do different things: the picture
/// opens itself, everything else opens the thread.
@MainActor
final class BoardMediaUITests: LiveUITestCase {
    func testTappingAThumbnailOpensTheMedia() throws {
        let app = launchApp()
        openDefaultBoard(app)

        let thumbnail = firstThumbnail(in: app)
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: Self.networkTimeout),
            "no thread thumbnail to tap"
        )
        thumbnail.tap()

        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "tapping a thumbnail should open the media, not the thread"
        )
        attach(app, name: "15-board-media")

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: 10),
            "closing the media should return to the board"
        )
    }

    func testTappingTheTextOpensTheThread() throws {
        let app = launchApp()
        openDefaultBoard(app)

        // The reply count sits in the card's text area, which opens the thread.
        replyCounts(app).firstMatch.tap()

        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "tapping the text should open the thread"
        )
        XCTAssertFalse(
            galleryCounter(app).exists,
            "tapping the text should not open the media"
        )
    }

    /// Thread thumbnails are identified by their file format.
    private func firstThumbnail(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment-"))
            .firstMatch
    }
}
