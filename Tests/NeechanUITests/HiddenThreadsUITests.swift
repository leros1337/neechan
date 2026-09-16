import XCTest

/// Hiding a thread has to remove it from the board.
///
/// The old test asserted only that the menu changed afterwards, which passed
/// while hiding did nothing visible whenever "Show hidden threads" happened to
/// be on.
@MainActor
final class HiddenThreadsUITests: LiveUITestCase {
    func testHidingRemovesTheThread() throws {
        let app = launchApp(extraArguments: ["-showsHiddenThreads", "NO"])
        unhideEverything(app)
        openDefaultBoard(app)

        // The row is identified by its own counts rather than by position: the
        // rest of the board shifts up when one goes, so counting rows proves
        // nothing.
        let row = replyCounts(app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.networkTimeout), "the board is empty")
        let identity = row.label

        hide(row, in: app)

        let gone = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", identity))
            .firstMatch
        XCTAssertTrue(
            waitForDisappearance(of: gone, timeout: 10),
            "the hidden thread is still on the board"
        )
        attach(app, name: "19-hidden")
    }

    /// With the setting on it comes back, but as a stub, not as a normal row.
    func testShowingHiddenThreadsGivesAStub() throws {
        let app = launchApp(extraArguments: ["-showsHiddenThreads", "YES"])
        unhideEverything(app)
        openDefaultBoard(app)

        let stubs = app.descendants(matching: .any).matching(identifier: "hidden-thread")
        XCTAssertEqual(stubs.count, 0, "the board started with something already hidden")

        hide(replyCounts(app).firstMatch, in: app)

        let stub = stubs.firstMatch
        XCTAssertTrue(
            stub.waitForExistence(timeout: 10),
            "showing hidden threads did not bring back a stub"
        )

        stub.tap()
        XCTAssertTrue(
            waitForDisappearance(of: stub, timeout: 10),
            "tapping the stub did not bring the thread back"
        )
    }

    /// Everything hidden is listed in Settings and can be brought back there.
    func testHiddenThreadsAreListedInSettings() throws {
        let app = launchApp(extraArguments: ["-showsHiddenThreads", "NO"])
        unhideEverything(app)
        openDefaultBoard(app)
        hide(replyCounts(app).firstMatch, in: app)

        switchToTab(app, "Settings")
        app.buttons["settings-eye.slash"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Hidden threads"].waitForExistence(timeout: 5),
            "the hidden threads screen did not open"
        )
        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: 5),
            "the thread that was hidden is not listed"
        )

        app.buttons["Unhide all"].firstMatch.tap()
        app.buttons["Unhide all"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Nothing hidden"].waitForExistence(timeout: 10),
            "unhiding everything left something behind"
        )
    }

    // MARK: Helpers

    /// Long-presses a row and hides it.
    ///
    /// The reply count is the handle because it is always hittable, whatever
    /// the row's layout.
    private func hide(_ row: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(row.waitForExistence(timeout: Self.networkTimeout), "the board is empty")
        row.press(forDuration: 1.0)

        let hide = app.buttons["Hide thread"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "the menu offers no way to hide")
        hide.tap()
    }

    /// Clears what earlier runs hid, so each test starts from a known board.
    ///
    /// Hidden threads outlive the app, and a test that assumes an empty slate
    /// otherwise passes or fails on whatever the last run left behind.
    private func unhideEverything(_ app: XCUIApplication) {
        switchToTab(app, "Settings")
        app.buttons["settings-eye.slash"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Hidden threads"].waitForExistence(timeout: 10))

        let unhideAll = app.buttons["Unhide all"].firstMatch
        if unhideAll.waitForExistence(timeout: 3) {
            unhideAll.tap()
            app.buttons["Unhide all"].firstMatch.tap()
            _ = app.staticTexts["Nothing hidden"].waitForExistence(timeout: 10)
        }
        // Back to the Settings root: a tab keeps its stack, so leaving it here
        // would strand a later visit on this screen. Swiped rather than tapped,
        // because a back button's label is the previous screen's title.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            )
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "could not get back to the settings list"
        )
        switchToTab(app, "Boards")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }
}
