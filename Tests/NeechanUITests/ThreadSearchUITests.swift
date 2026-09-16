import XCTest

/// Searching while reading a thread must search that thread, and must not take
/// the reader out of it.
@MainActor
final class ThreadSearchUITests: LiveUITestCase {
    func testSearchingInAThreadFiltersItsPosts() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        let postsBefore = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "№")
        ).count
        XCTAssertGreaterThan(postsBefore, 0, "no posts rendered")

        let field = try openSearch(app)
        field.typeText("щщzzzнеттакого")

        // A query nothing matches must empty the list, which proves the field
        // filters this thread rather than searching somewhere else.
        let empty = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "No Results")
        ).firstMatch
        let postsAfter = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "№")
        ).count
        XCTAssertTrue(
            empty.waitForExistence(timeout: 5) || postsAfter < postsBefore,
            "searching did not filter the thread"
        )

        attach(app, name: "12-thread-search")
    }

    func testSearchingKeepsTheReaderInTheThread() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        let field = try openSearch(app)
        field.typeText("а")

        // The thread's own navigation bar must still be there: searching is not
        // a separate screen, so the back gesture still leads to the board.
        XCTAssertTrue(
            app.navigationBars.firstMatch.exists,
            "searching pushed the reader out of the thread"
        )

        // Clearing the search restores the thread.
        if app.buttons["Cancel"].firstMatch.exists {
            app.buttons["Cancel"].firstMatch.tap()
        }
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "№"))
                .firstMatch.waitForExistence(timeout: 10),
            "the thread did not come back after searching"
        )
    }

    /// Reveals the thread's search field through the menu, which is the way a
    /// reader finds it: the field itself sits above the content until pulled
    /// down.
    private func openSearch(_ app: XCUIApplication) throws -> XCUIElement {
        let menu = app.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "the thread has no actions menu")
        menu.tap()

        let action = app.buttons["Search in thread"].firstMatch
        XCTAssertTrue(
            action.waitForExistence(timeout: 10),
            "the menu does not offer searching the thread"
        )
        action.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 10),
            "a thread should offer a search field of its own"
        )
        if !field.value.debugDescription.isEmpty {
            field.tap()
        }
        return field
    }

}
