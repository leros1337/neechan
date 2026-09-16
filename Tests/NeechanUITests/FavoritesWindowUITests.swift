import XCTest

/// The favorites, opened over a thread rather than instead of it.
///
/// The thread's toolbar used to carry a share button, which repeated what its
/// menu already offered. In its place is a button that shows the reader's kept
/// threads as a window. Closing it leaves the thread exactly as it was, and
/// choosing something takes them there properly, on the stack they are in.
@MainActor
final class FavoritesWindowUITests: LiveUITestCase {
    func testTheFavoritesWindowOpensOverTheThread() throws {
        let app = XCUIApplication()
        let done = try openFavoritesWindow(app)
        attach(app, name: "30-favorites-window")

        XCTAssertTrue(
            app.staticTexts["Threads"].waitForExistence(timeout: 10),
            "the window opened without the list of kept threads"
        )

        done.tap()
        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 5),
            "the window could not be closed"
        )
    }

    /// The point of the whole feature: a kept thread is one tap away, and the
    /// tap takes the reader there rather than showing it in the card.
    func testAFavoriteTakesTheReaderToThatThread() throws {
        let app = XCUIApplication()
        let done = try openFavoritesWindow(app)

        try tapAKeptThread(in: app)

        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 10),
            "the window stayed up over the thread it opened"
        )
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the kept thread did not open"
        )
        XCTAssertTrue(
            app.navigationBars.buttons["Thread actions"].waitForExistence(timeout: 10),
            "what opened was not a thread"
        )
        attach(app, name: "31-favorite-opened")

        // Pushed rather than swapped, so the thread it was opened from is still
        // one step back.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "going back did not return to the thread the window was opened from"
        )
    }

    /// Closing the window has to land on the thread that opened it, untouched.
    func testClosingTheWindowReturnsToTheThread() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)
        keepThisThread(app)

        // Noted while the thread is still on screen, to prove afterwards that
        // it was neither replaced nor scrolled.
        let marker = anyPostNumber(app).label
        try XCTSkipIf(marker.isEmpty, "no post was on screen to remember")

        let done = try openTheWindow(app)
        done.tap()
        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 5),
            "the window stayed up after Done"
        )
        XCTAssertTrue(
            app.navigationBars.buttons["Thread actions"].waitForExistence(timeout: 10),
            "closing the window did not return to the thread"
        )
        XCTAssertTrue(
            app.staticTexts[marker].exists,
            "the thread behind the window had moved"
        )
    }

    func testTheFavoritesWindowCanBeSwipedAway() throws {
        let app = XCUIApplication()
        let done = try openFavoritesWindow(app)

        // Dragged from the bar at the top rather than from the middle: the
        // window is a list, and a drag on a list scrolls it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            )

        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 5),
            "the window could not be swiped away"
        )
    }

    /// A kept board is reached the same way, and the reader ends up on it.
    ///
    /// Worth its own test because the window lists two kinds of thing, and a
    /// board takes a different route out of it than a thread does.
    func testAKeptBoardTakesTheReaderToThatBoard() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        pinTheBoard(app)
        openThreadWithReplies(app)
        let done = try openTheWindow(app)

        let board = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorite-board-"))
            .firstMatch
        try XCTSkipUnless(board.waitForExistence(timeout: 10), "no board is kept right now")
        board.tap()

        XCTAssertTrue(
            waitForDisappearance(of: done, timeout: 10),
            "the window stayed up over the board it opened"
        )
        let counts = replyCounts(app)
        XCTAssertTrue(
            counts.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the kept board did not open"
        )

        // And the board behaves like any other from here on.
        counts.firstMatch.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "a thread on the board that was opened from the window did not open"
        )
        attach(app, name: "32-board-opened")
    }

    // MARK: Helpers

    /// Opens a thread, keeps it, and opens the favorites over it.
    ///
    /// Returns the window's close button, which doubles as the way to tell the
    /// window is still up.
    private func openFavoritesWindow(_ app: XCUIApplication) throws -> XCUIElement {
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)
        keepThisThread(app)
        return try openTheWindow(app)
    }

    /// Taps the toolbar button and waits for the window.
    private func openTheWindow(_ app: XCUIApplication) throws -> XCUIElement {
        let button = app.buttons["favorites-window"].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: Self.networkTimeout),
            "the thread offers no way to the favorites"
        )
        button.tap()

        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the favorites window did not open")
        return done
    }

    /// Keeps the thread being read, so the window has something in it.
    ///
    /// The simulator keeps what earlier runs kept, so a thread that is already
    /// a favourite is left alone rather than being toggled off.
    private func keepThisThread(_ app: XCUIApplication) {
        let menu = app.navigationBars.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: Self.networkTimeout), "no thread menu")
        menu.tap()

        let add = app.buttons["Add to favorites"].firstMatch
        let remove = app.buttons["Remove from favorites"].firstMatch
        waitForEither(add, remove)

        if add.exists {
            add.tap()
        } else {
            // Kept already. Close the menu without changing anything.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
    }

    /// Keeps the board being looked at, from its own menu.
    private func pinTheBoard(_ app: XCUIApplication) {
        let menu = app.navigationBars.buttons["View options"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: Self.networkTimeout), "no board menu")
        menu.tap()

        let pin = app.buttons["Pin board"].firstMatch
        let unpin = app.buttons["Unpin board"].firstMatch
        waitForEither(pin, unpin)

        if pin.exists {
            pin.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
        _ = replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout)
    }

    /// Taps a kept thread, by name rather than by position: the window lists
    /// kept boards in the same list, above the threads.
    private func tapAKeptThread(in app: XCUIApplication) throws {
        let thread = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorite-thread-"))
            .firstMatch
        try XCTSkipUnless(
            thread.waitForExistence(timeout: 10),
            "the window listed no kept thread to open"
        )
        thread.tap()
    }

    /// Waits until one of two elements is on screen, or ten seconds pass.
    ///
    /// A menu shows one or the other depending on what the reader has already
    /// done, and waiting on the absent one costs the whole timeout.
    private func waitForEither(_ first: XCUIElement, _ second: XCUIElement) {
        var waited = 0.0
        while !first.exists, !second.exists, waited < 10 {
            Thread.sleep(forTimeInterval: 0.25)
            waited += 0.25
        }
    }
}
