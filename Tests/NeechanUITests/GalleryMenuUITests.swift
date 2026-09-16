import XCTest

/// A long press in the gallery offers what to do with the file.
@MainActor
final class GalleryMenuUITests: LiveUITestCase {
    func testLongPressOffersGoToPostSaveAndShare() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstAttachment(app)

        let page = app.images.firstMatch.exists ? app.images.firstMatch : app.otherElements.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: Self.networkTimeout), "the gallery did not open")
        page.press(forDuration: 1.0)

        for action in ["Save", "Share"] {
            XCTAssertTrue(
                app.buttons[action].firstMatch.waitForExistence(timeout: 10),
                "the long-press menu does not offer \(action)"
            )
        }
        XCTAssertTrue(
            goToPostButton(app).exists,
            "the long-press menu does not offer a way back to the post"
        )

        attach(app, name: "20-gallery-menu")
    }

    /// Going to the post closes the gallery and leaves the thread on that post.
    func testGoToPostReturnsToTheThread() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstAttachment(app)

        let page = app.images.firstMatch.exists ? app.images.firstMatch : app.otherElements.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: Self.networkTimeout), "the gallery did not open")
        page.press(forDuration: 1.0)

        let goToPost = goToPostButton(app)
        XCTAssertTrue(goToPost.waitForExistence(timeout: 10), "no way back to the post")
        // The identifier names the post the thread should end up on.
        let postNumber = goToPost.identifier.replacingOccurrences(of: "go-to-post-", with: "")
        goToPost.tap()

        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: 15),
            "going to the post did not return to the thread"
        )
        XCTAssertTrue(
            app.staticTexts["\u{2116}\(postNumber)"].waitForExistence(timeout: 15),
            "the thread did not scroll to post \(postNumber)"
        )
    }

    /// The menu's way back to the post. Found by identifier, which carries the
    /// post number that the item itself no longer shows.
    private func goToPostButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "go-to-post-"))
            .firstMatch
    }
}
