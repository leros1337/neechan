import XCTest

/// Reading a board page by page, the way the site itself paginates it.
///
/// A board opens as the catalog unless told otherwise, so these pin the
/// preference rather than relying on whatever the last run left behind.
@MainActor
final class BoardPagingUITests: LiveUITestCase {
    private func launchPaged() -> XCUIApplication {
        launchApp(extraArguments: ["-forum.catalogByDefault", "NO"])
    }

    func testPagingForwardAndBack() throws {
        let app = launchPaged()
        openDefaultBoard(app)

        let counter = app.descendants(matching: .any)
            .matching(identifier: "page-counter")
            .firstMatch
        XCTAssertTrue(
            counter.waitForExistence(timeout: Self.networkTimeout),
            "the page control is missing"
        )
        XCTAssertTrue(counter.label.hasPrefix("Page 1 of "), "did not start on page 1")

        app.buttons["Older threads"].tap()
        XCTAssertTrue(
            waitFor(counter, toStartWith: "Page 2 of "),
            "going forward did not change the page, it stayed on \(counter.label)"
        )

        app.buttons["Newer threads"].tap()
        XCTAssertTrue(
            waitFor(counter, toStartWith: "Page 1 of "),
            "going back did not change the page, it stayed on \(counter.label)"
        )
    }

    func testPagingLoadsDifferentThreads() throws {
        let app = launchPaged()
        openDefaultBoard(app)

        let firstThread = app.cells.staticTexts.firstMatch
        XCTAssertTrue(firstThread.waitForExistence(timeout: Self.networkTimeout))
        let onPageOne = firstThread.label

        app.buttons["Older threads"].tap()
        Thread.sleep(forTimeInterval: 3)

        XCTAssertNotEqual(
            onPageOne,
            app.cells.staticTexts.firstMatch.label,
            "the next page showed the same threads"
        )
    }

    /// The catalog is one request for the whole board, which is how most
    /// readers use it, so it is what a board opens as.
    func testABoardOpensAsTheCatalogUntilToldOtherwise() throws {
        let app = launchApp()
        openDefaultBoard(app)

        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "page-counter")
                .firstMatch
                .waitForExistence(timeout: 5),
            "the board opened page by page rather than as the catalog"
        )
    }

    private func waitFor(_ element: XCUIElement, toStartWith prefix: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.networkTimeout)
        while Date() < deadline {
            if element.label.hasPrefix(prefix) { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }
}
