import XCTest

/// Keeping a thread on the device, on both imageboards.
///
/// The 4chan case is the one worth a test: the menu item was missing there for
/// as long as the archiver read every saved file as 2ch's shape, so its absence
/// was correct and its presence is the fix.
@MainActor
final class OfflineSaveUITests: LiveUITestCase {
    /// Opens a board's first thread and its actions menu.
    private func openThreadMenu(_ app: XCUIApplication, board: String) {
        let row = app.staticTexts[board]
        XCTAssertTrue(
            row.waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )
        row.tap()
        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "\(board) did not load its threads"
        )
        useCardsLayout(app)
        openFirstThread(app)

        let menu = app.navigationBars.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the thread has no actions menu")
        menu.tap()
    }

    /// The save item is a submenu rather than a button, and submenus are not
    /// reported as buttons -- so it is found by identifier, whichever element
    /// kind it turns out to be.
    private func saveItem(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "save-for-offline").firstMatch
    }

    func testAFourchanThreadOffersSavingForOffline() throws {
        let app = launchApp(pinsImageboard: false)
        switchToImageboard("4chan", in: app)
        // /3/ rather than /a/: the board list is long and lazily built, so a
        // code further down it is not in the hierarchy to be tapped. Which
        // board this is does not matter -- the save item is what is under test.
        openThreadMenu(app, board: "/3/")

        XCTAssertTrue(
            saveItem(app).waitForExistence(timeout: 10),
            "a 4chan thread offers no way to keep a copy"
        )
        attach(app, name: "save-offline-fourchan")
    }

    /// The path that already worked, so a regression there is caught too.
    func testA2chThreadStillOffersSavingForOffline() throws {
        let app = launchApp()
        openThreadMenu(app, board: "/b/")

        XCTAssertTrue(
            saveItem(app).waitForExistence(timeout: 10),
            "a 2ch thread stopped offering a saved copy"
        )
    }
}
