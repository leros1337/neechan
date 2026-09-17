import XCTest

/// Switching imageboards, against both live sites.
///

/// Deliberately not written against a particular thread existing: these run on
/// the real sites, and an assertion about today's front page is how a test like
/// this turns flaky. What is asserted is the requirement — that the reader's
/// own data belongs to the imageboard it came from.
@MainActor
final class ImageboardSwitchUITests: LiveUITestCase {
    /// Taps the switcher on the board list itself, which is the control a
    /// reader actually reaches for.
    private func selectImageboard(_ name: String, in app: XCUIApplication) {
        // Back to the board list first: the switcher lives on it, and the tab
        // may still be showing a board or a thread pushed on top.
        app.buttons["Boards"].firstMatch.tap()
        for _ in 0..<4 where !app.segmentedControls["imageboard-picker"].exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        let picker = app.segmentedControls["imageboard-picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: Self.networkTimeout),
            "the board list has no imageboard switcher"
        )
        let segment = picker.buttons[name]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "no \(name) segment")
        segment.tap()
    }

    func testTheSwitcherIsOnTheBoardListAndCanBeTapped() {
        let app = launchApp()
        let picker = app.segmentedControls["imageboard-picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: Self.networkTimeout),
            "the switcher is not reachable on the board list"
        )
        XCTAssertTrue(picker.buttons["2ch"].exists)
        XCTAssertTrue(picker.buttons["4chan"].exists)
        XCTAssertTrue(picker.buttons["4chan"].isHittable, "the switcher cannot be tapped")
    }

    /// Each site's board list is its own, which is the visible half of the
    /// switch working at all.
    func testEachImageboardShowsItsOwnBoards() {
        let app = launchApp()
        XCTAssertTrue(
            app.staticTexts["/b/"].waitForExistence(timeout: Self.networkTimeout),
            "2ch's board list did not load"
        )

        selectImageboard("4chan", in: app)
        // /3/ exists only on 4chan, and is the board code that used to be
        // rejected outright for having no letter in it.
        XCTAssertTrue(
            app.staticTexts["/3/"].waitForExistence(timeout: Self.networkTimeout),
            "4chan's board list did not load"
        )
        attach(app, name: "30-fourchan-boards")

        selectImageboard("2ch", in: app)
        XCTAssertTrue(
            app.staticTexts["/b/"].waitForExistence(timeout: Self.networkTimeout),
            "2ch's board list did not come back"
        )
    }

    /// The requirement itself: a favourite kept on one imageboard is not shown
    /// while the other is selected, and is still there on return.
    func testFavoritesBelongToTheImageboardTheyCameFrom() {
        let app = launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let menu = app.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: Self.networkTimeout), "no thread menu")
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

        // Over to 4chan: the list is the other site's, and this is not on it.
        selectImageboard("4chan", in: app)
        app.buttons["Favorites"].firstMatch.tap()
        XCTAssertFalse(
            app.staticTexts["Threads"].waitForExistence(timeout: 5),
            "2ch's favourites are showing while 4chan is selected"
        )
        attach(app, name: "32-favorites-are-per-imageboard")

        // And back: nothing was lost on the way.
        selectImageboard("2ch", in: app)
        app.buttons["Favorites"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Threads"].waitForExistence(timeout: 10),
            "the favourite did not survive the round trip"
        )
    }

    /// 4chan has none of these, so offering them would lead nowhere.
    func testWhatFourchanCannotDoIsNotOffered() {
        let app = launchApp()
        selectImageboard("4chan", in: app)
        XCTAssertTrue(
            app.staticTexts["/3/"].waitForExistence(timeout: Self.networkTimeout),
            "4chan's board list did not load"
        )
        XCTAssertFalse(
            app.buttons["User boards"].exists,
            "reader-made boards are a 2ch idea and 4chan has none"
        )
    }

    /// A 4chan thread reads end to end: its posts, its markup and its files,
    /// which all come from a different host than the JSON does.
    func testAFourchanThreadReads() {
        let app = launchApp(
            extraArguments: ["-imageboard", "fourchan", "-defaultBoard", "po"],
            pinsImageboard: false
        )
        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "4chan's catalog did not load"
        )
        openFirstThread(app)
        XCTAssertTrue(
            app.buttons["Thread actions"].firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "a 4chan thread did not open"
        )
        attach(app, name: "33-fourchan-thread")
    }

    /// The imageboard is a preference, and a preference survives the app being
    /// closed. Driven the way a reader would: choose it, quit, come back.
    func testTheChosenImageboardSurvivesARelaunch() {
        let app = launchApp(pinsImageboard: false)
        selectImageboard("4chan", in: app)
        XCTAssertTrue(
            app.staticTexts["/3/"].waitForExistence(timeout: Self.networkTimeout),
            "4chan's board list did not load"
        )

        app.terminate()
        let relaunched = launchApp(pinsImageboard: false)
        XCTAssertTrue(
            relaunched.staticTexts["/3/"].waitForExistence(timeout: Self.networkTimeout),
            "the app came back on a different imageboard than the one chosen"
        )
        XCTAssertTrue(
            relaunched.segmentedControls["imageboard-picker"].buttons["4chan"].isSelected,
            "the switcher came back showing the wrong imageboard"
        )

        // Left as it was found, so the rest of the suite starts on 2ch.
        selectImageboard("2ch", in: relaunched)
    }
}
