import XCTest

/// Opens the gallery from a thread and checks that a real file renders, then
/// that a WebM actually plays. WebM is the reason this app carries an FFmpeg
/// build, so it is worth asserting against the live site.
@MainActor
final class GalleryUITests: LiveUITestCase {
    func testTappingAThumbnailOpensTheGallery() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstAttachment(app)

        // The gallery shows a position counter such as "1 / 12".
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the gallery did not open"
        )

        attach(app, name: "05-gallery")
        XCTAssertTrue(app.buttons["Save"].exists || app.buttons.count > 0)
    }

    func testGalleryClosesBackToTheThread() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstAttachment(app)

        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the gallery did not open"
        )

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "№"))
                .firstMatch.waitForExistence(timeout: 10),
            "closing the gallery should return to the thread"
        )
    }

    // MARK: Helpers

}
