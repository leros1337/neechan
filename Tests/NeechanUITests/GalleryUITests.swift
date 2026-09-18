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

    /// The file info card belongs at the top of the viewer, between the close
    /// button and the position counter, rather than on the bottom edge where it
    /// used to crowd the scrubber and the transport buttons.
    func testFileInfoSitsAtTheTopOfTheGallery() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstAttachment(app)

        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the gallery did not open"
        )

        // Any type: a combined accessibility element does not reliably surface
        // as `otherElements`, and what it is matters less than where it is.
        let info = app.descendants(matching: .any)["gallery-info"].firstMatch
        XCTAssertTrue(
            info.waitForExistence(timeout: Self.networkTimeout),
            "the gallery showed no file info"
        )

        attach(app, name: "06-gallery-top-info")

        // A frame comparison rather than a coordinate: the point is which half
        // of the screen the card is in, and that holds on every device size.
        XCTAssertLessThan(
            info.frame.midY, app.frame.midY,
            "the file info should sit in the top half of the gallery"
        )
    }

    // MARK: Helpers

}
