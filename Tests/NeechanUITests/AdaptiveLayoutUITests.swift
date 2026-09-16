import XCTest

/// The iPad shell: a sidebar of sections beside the content.
@MainActor
final class AdaptiveLayoutUITests: LiveUITestCase {
    /// On a wide window the sections are a sidebar, not a tab bar, and picking
    /// one changes what the detail column shows.
    func testSidebarReplacesTabBar() throws {
        let app = launchApp()

        let boards = app.staticTexts["/b/"]
        XCTAssertTrue(
            boards.waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )
        XCTAssertEqual(app.tabBars.count, 0, "a wide window should not show a tab bar")

        let favorites = sidebarRow(app, "Favorites")
        XCTAssertTrue(favorites.waitForExistence(timeout: 5), "the sidebar has no Favorites row")
        favorites.tap()
        XCTAssertTrue(
            app.navigationBars["Favorites"].waitForExistence(timeout: 5),
            "picking a section did not change the detail column"
        )

        sidebarRow(app, "Boards").tap()
        XCTAssertTrue(
            boards.waitForExistence(timeout: Self.networkTimeout),
            "going back to Boards did not restore the list"
        )
    }

    /// A thread opens inside the detail column and keeps the sidebar.
    func testThreadOpensBesideTheSidebar() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        XCTAssertTrue(
            sidebarRow(app, "Boards").exists,
            "the sidebar disappeared when a thread opened"
        )
    }

    /// A section in the sidebar. The split view draws these as buttons on some
    /// devices and as cells on others, so both are accepted.
    private func sidebarRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let button = app.buttons[title]
        return button.exists ? button : app.cells.staticTexts[title]
    }
}
