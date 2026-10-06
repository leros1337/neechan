import XCTest

/// The board's menu reaches what the top of the list otherwise keeps to itself:
/// the filter field, which the system tucks away once the list scrolls, and a
/// reload, which pulling down only offers from the very top.
@MainActor
final class BoardMenuUITests: LiveUITestCase {
    /// The menu brings the filter back from anywhere in the list, ready to
    /// type into, and it filters the board rather than searching the server.
    func testFilterThreadsFromTheMenuFocusesTheField() throws {
        let app = launchApp()
        openDefaultBoard(app)
        scrollDown(app, swipes: 3)

        chooseFromMenu("Filter threads", in: app)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the board's filter field did not appear")
        // Typing into the app rather than the field: it only lands if the
        // menu really left the field focused.
        app.typeText("щщzzzнеттакого")
        XCTAssertTrue(
            waitForDisappearance(of: replyCounts(app).firstMatch, timeout: 10),
            "a query that matches nothing still left threads on the board"
        )
        attach(app, name: "board-menu-filter")
    }

    /// Reloading from part way down fetches the board and goes back to the top,
    /// which is where a board in bump order puts what is new.
    func testReloadFromTheMenuReturnsToTheTop() throws {
        let app = launchApp()
        openDefaultBoard(app)

        let top = firstCard(app)
        for _ in 0..<8 where top.exists && top.isHittable {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertFalse(top.exists && top.isHittable, "the board is too short to scroll away from the top")

        chooseFromMenu("Reload", in: app)

        let backAtTop = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: top
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [backAtTop], timeout: Self.networkTimeout), .completed,
            "reloading did not bring the board back to its top"
        )
        XCTAssertFalse(app.buttons["Try again"].exists, "reloading turned the board into an error")
        attach(app, name: "board-menu-reload")
    }

    // MARK: Helpers

    private func chooseFromMenu(_ item: String, in app: XCUIApplication) {
        let options = app.buttons["View options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: Self.networkTimeout), "the board has no view options")
        options.tap()

        let choice = app.buttons[item].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the board's menu does not offer '\(item)'")
        choice.tap()
    }

    private func scrollDown(_ app: XCUIApplication, swipes: Int) {
        for _ in 0..<swipes { app.swipeUp(velocity: .fast) }
    }

    /// The first thread on the board, found again by its longest label: the
    /// opening post's preview, which no other card on screen shares. A board
    /// opens with its pinned threads, so this stays first across a reload.
    private func firstCard(_ app: XCUIApplication) -> XCUIElement {
        let cell = app.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: Self.networkTimeout), "the board shows no threads")
        // The preview is parsed after the row first draws.
        Thread.sleep(forTimeInterval: 1)
        let label = cell.descendants(matching: .any).allElementsBoundByIndex
            .map(\.label)
            .max { $0.count < $1.count } ?? ""
        XCTAssertGreaterThan(label.count, 10, "the first thread has nothing to recognise it by")
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }
}
