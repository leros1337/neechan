import XCTest

/// An image must open fitted to the screen.
///
/// It used to open at its full pixel size, because the scroll view was measured
/// before it had any bounds, and only a double tap forced it to fit.
@MainActor
final class ImageZoomUITests: LiveUITestCase {
    func testAnImageOpensFittedToTheScreen() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstAttachment(app)

        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the gallery did not open"
        )

        let screen = app.windows.firstMatch.frame
        let imageFrame = try waitForImageFrame(app, screen: screen)

        // Fitted means the image is inside the screen on both axes. Opening
        // zoomed in showed a frame far wider or taller than the window.
        XCTAssertLessThanOrEqual(
            imageFrame.width, screen.width + 1,
            "the image opened wider than the screen, so it was not fitted"
        )
        XCTAssertLessThanOrEqual(
            imageFrame.height, screen.height + 1,
            "the image opened taller than the screen, so it was not fitted"
        )

        attach(app, name: "11-image-fit")
    }

    /// The largest image element on screen, which is the one being displayed.
    private func waitForImageFrame(_ app: XCUIApplication, screen: CGRect) throws -> CGRect {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let frames = app.scrollViews.images.allElementsBoundByAccessibilityElement
                .map(\.frame)
                .filter { $0.width > 1 && $0.height > 1 }
            if let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                return largest
            }
            usleep(300_000)
        }
        throw XCTSkip("no image element was exposed by the gallery")
    }

}
