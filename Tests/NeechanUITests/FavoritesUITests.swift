import XCTest

/// Favourites, hiding and the watcher, driven against the live site.
@MainActor
final class FavoritesUITests: LiveUITestCase {
    func testAThreadCanBeFavouritedAndAppearsInTheList() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let menu = app.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "the thread has no actions menu")
        menu.tap()

        let add = app.buttons["Add to favorites"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the menu cannot favourite a thread")
        add.tap()

        XCTAssertTrue(leaveThread(app), "the tabs did not come back after the thread")
        app.buttons["Favorites"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Threads"].waitForExistence(timeout: 10),
            "the favourited thread did not reach the list"
        )
        attach(app, name: "19-favorites")
    }

    /// Hiding a thread is covered properly by `HiddenThreadsUITests`, which
    /// asserts the row actually goes. This one only checks the menu is wired
    /// up, so it stays short.
    func testAThreadCanBeHiddenFromItsMenu() throws {
        let app = launchApp()
        openDefaultBoard(app)

        let firstThread = replyCounts(app).firstMatch
        XCTAssertTrue(firstThread.waitForExistence(timeout: Self.networkTimeout))
        firstThread.press(forDuration: 1.0)

        let hide = app.buttons["Hide thread"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "a thread cannot be hidden")
        hide.tap()

        app.navigationBars.buttons["View options"].firstMatch.tap()
        // A Toggle inside a menu is drawn as a checkmark item, so it arrives as
        // a menu button rather than as a switch.
        let showHidden = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Show hidden threads"))
            .firstMatch
        XCTAssertTrue(
            showHidden.waitForExistence(timeout: 10),
            "the board does not offer to show hidden threads"
        )
    }

    func testAnAutohideRuleCanBeWrittenAndTested() throws {
        let app = launchApp()

        app.buttons["Settings"].firstMatch.tap()
        let autohide = app.buttons["Autohide"].firstMatch
        XCTAssertTrue(autohide.waitForExistence(timeout: 10), "Settings has no autohide entry")
        autohide.tap()

        app.buttons["New rule"].firstMatch.tap()

        let fields = app.textFields
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10), "the editor has no fields")
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("спам")

        // The editor says whether the rule would hit the text being tried.
        let test = fields.element(boundBy: 1)
        test.tap()
        test.typeText("это спам")

        XCTAssertTrue(
            app.staticTexts["This text would be hidden"].waitForExistence(timeout: 5),
            "the rule tester did not report a match"
        )
        attach(app, name: "20-autohide-rule")
    }
}
