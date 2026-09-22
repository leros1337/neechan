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

    /// The thread's gallery grid offers the same menu on each thumbnail, without
    /// opening the file first.
    func testGridLongPressOffersGoToPostSaveAndShare() throws {
        let app = launchApp()
        let cell = openGalleryGrid(app)
        cell.press(forDuration: 1.0)

        for action in ["Save", "Share"] {
            XCTAssertTrue(
                app.buttons[action].firstMatch.waitForExistence(timeout: 10),
                "the grid's long-press menu does not offer \(action)"
            )
        }
        XCTAssertTrue(
            goToPostButton(app).exists,
            "the grid's long-press menu does not offer a way back to the post"
        )

        attach(app, name: "21-gallery-grid-menu")
    }

    /// Going to the post from the grid closes it and leaves the thread there.
    func testGridGoToPostReturnsToTheThread() throws {
        let app = launchApp()
        let cell = openGalleryGrid(app)
        cell.press(forDuration: 1.0)

        let goToPost = goToPostButton(app)
        XCTAssertTrue(goToPost.waitForExistence(timeout: 10), "no way back to the post")
        let postNumber = goToPost.identifier.replacingOccurrences(of: "go-to-post-", with: "")
        goToPost.tap()

        XCTAssertTrue(
            app.staticTexts["\u{2116}\(postNumber)"].waitForExistence(timeout: 15),
            "the thread did not scroll to post \(postNumber)"
        )
        XCTAssertFalse(app.buttons["Done"].exists, "the gallery grid stayed open")
    }

    /// Opens the first thread's gallery grid and returns its first thumbnail.
    private func openGalleryGrid(_ app: XCUIApplication) -> XCUIElement {
        openDefaultBoard(app)
        openFirstThread(app)

        app.navigationBars.buttons["Thread actions"].tap()
        let gallery = app.buttons["Gallery"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 5), "the gallery action is missing")
        gallery.tap()

        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'"))
            .firstMatch
        XCTAssertTrue(
            cell.waitForExistence(timeout: Self.networkTimeout),
            "the gallery grid showed no attachments"
        )
        return cell
    }

    /// The menu's way back to the post. Found by identifier, which carries the
    /// post number that the item itself no longer shows.
    private func goToPostButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "go-to-post-"))
            .firstMatch
    }
}
