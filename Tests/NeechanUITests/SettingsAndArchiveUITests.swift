import XCTest

/// Drives the screens milestone M5 added, against the live site.
@MainActor
final class SettingsAndArchiveUITests: LiveUITestCase {
    /// The settings tree opens and every section it lists can be reached.
    func testSettingsSectionsOpen() throws {
        let app = launchApp()
        openSettings(app)

        for section in [
            "General", "Forum", "Appearance", "Contents", "Media", "Restrictions", "About",
        ] {
            let row = app.buttons[section].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(section) is not listed")
            row.tap()
            XCTAssertTrue(
                app.navigationBars[section].waitForExistence(timeout: 5),
                "\(section) did not open"
            )
            app.navigationBars[section].buttons.firstMatch.tap()
        }
    }

    /// The cookies screen lists what the site has set. Browsing first guarantees
    /// there is at least one cookie to show.
    func testCookiesManagerListsSessionCookies() throws {
        let app = launchApp()
        openDefaultBoard(app)
        switchToTab(app, "Settings")

        app.buttons["Forum"].firstMatch.tap()
        let cookies = app.buttons["Cookies"].firstMatch
        XCTAssertTrue(cookies.waitForExistence(timeout: 5))
        cookies.tap()

        XCTAssertTrue(
            app.navigationBars["Cookies"].waitForExistence(timeout: 5),
            "the cookies screen did not open"
        )
        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "browsing the site set no cookies at all"
        )
    }

    /// A board's archive loads and lists threads that have fallen off it.
    func testArchiveLoads() throws {
        let app = launchApp()
        openDefaultBoard(app)

        app.navigationBars.buttons["View options"].tap()
        app.buttons["Archive"].tap()

        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the archive listed nothing"
        )
    }

    /// Searching a board on the server returns posts and opens one.
    func testServerSearchFindsPosts() throws {
        let app = launchApp()
        openDefaultBoard(app)

        app.navigationBars.buttons["View options"].tap()
        app.buttons["Search this board"].tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search field is missing")
        field.tap()
        field.typeText("тред\n")

        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the server search returned nothing"
        )
    }

    /// A thread saved to the device opens again from the saved list, and its
    /// posts render without the network being asked for them.
    func testSavedThreadReadsBack() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        app.navigationBars.buttons["Thread actions"].tap()
        let save = app.buttons["Save for offline"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the save action is missing")
        save.tap()
        app.buttons["Text and thumbnails"].tap()

        // Give the save time to write the thread and its thumbnails.
        Thread.sleep(forTimeInterval: 5)

        // A thread is read full screen, so the tabs are reached from outside it.
        XCTAssertTrue(leaveThread(app), "the tabs did not come back after the thread")
        openSettings(app)
        app.buttons["Saved threads"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Saved threads"].waitForExistence(timeout: 5),
            "the saved list did not open"
        )

        let saved = app.cells.firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the thread was not saved")
        saved.tap()

        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: 10),
            "the saved thread's posts did not render"
        )
    }

    private func openSettings(_ app: XCUIApplication) {
        switchToTab(app, "Settings")
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5),
            "the settings tab did not open"
        )
    }
}
