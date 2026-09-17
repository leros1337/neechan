import XCTest

/// The content gates, against the live sites.
///
/// Written against the requirement rather than against today's front page: what
/// is asserted is that a restricted board cannot be seen or reached, not that a
/// particular thread is on it.
@MainActor
final class RestrictionsUITests: LiveUITestCase {
    /// Launches with the 21+ gate closed, which is what the reader does from
    /// the Restrictions screen.
    private func launchWithMatureOff() -> XCUIApplication {
        launchApp(
            extraArguments: ["-restrictions.allowsMature", "NO"],
            pinsRestrictions: false
        )
    }

    private func openSettings(_ app: XCUIApplication) {
        switchToTab(app, "Settings")
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "the settings tab did not open"
        )
    }

    func testTheRestrictionsScreenHoldsAllThreeControls() {
        let app = launchApp()
        openSettings(app)

        let row = app.buttons["Restrictions"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Restrictions is not in Settings")
        row.tap()

        for identifier in ["nsfw-mode-toggle", "mature-toggle", "posting-toggle"] {
            XCTAssertTrue(
                app.switches[identifier].waitForExistence(timeout: 5),
                "\(identifier) is missing"
            )
        }
        // The gates ship open and NSFW mode ships closed.
        XCTAssertEqual(app.switches["mature-toggle"].value as? String, "1")
        XCTAssertEqual(app.switches["posting-toggle"].value as? String, "1")
    }

    /// Turning the gate on again must ask, which is the whole point of it.
    ///
    /// Driven entirely through the screen rather than from a launch argument:
    /// an argument lives in `UserDefaults`' argument domain, which outranks
    /// anything the app writes, so a pinned preference cannot be moved at all.
    /// Starting from whatever is stored and leaving it as found keeps this from
    /// disturbing the tests that run after it.
    func testTurningTheGateBackOnAsksHowOldTheReaderIs() {
        let app = launchApp(pinsRestrictions: false)
        openSettings(app)
        app.buttons["Restrictions"].firstMatch.tap()

        let toggle = app.switches["mature-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the 21+ toggle is missing")
        if toggle.value as? String == "0" {
            confirmAge(in: app, toggle: toggle)
        }
        XCTAssertEqual(toggle.value as? String, "1", "could not reach a known starting state")

        // Off is the safe direction, and asks nothing.
        flip(toggle)
        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 2),
            "closing the gate should not need confirming"
        )
        XCTAssertEqual(toggle.value as? String, "0", "the gate did not close")

        // On asks, and a refusal leaves it closed.
        flip(toggle)
        XCTAssertTrue(
            app.alerts.firstMatch.waitForExistence(timeout: 5),
            "the gate opened without asking how old the reader is"
        )
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(toggle.value as? String, "0", "cancelling opened the gate anyway")

        // Left as found, so the rest of the suite sees a whole directory.
        confirmAge(in: app, toggle: toggle)
        XCTAssertEqual(toggle.value as? String, "1")
    }

    /// Taps the switch itself rather than the row.
    ///
    /// A `Toggle` in this Form reports the whole row as its element, and its
    /// centre is dead space between the label and the control, so the plain
    /// `tap()` lands on nothing.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func confirmAge(in app: XCUIApplication, toggle: XCUIElement) {
        flip(toggle)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no age prompt")
        alert.buttons["I am 21 or older"].tap()
    }

    /// The requirement itself, on the directory the reader actually browses.
    func testRestrictedBoardsAreNotInTheDirectory() {
        let app = launchWithMatureOff()

        XCTAssertTrue(
            app.staticTexts["/a/"].waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )
        XCTAssertFalse(app.staticTexts["/hc/"].exists, "an adult board was listed")
        XCTAssertFalse(app.staticTexts["/b/"].exists, "/b/ was listed")
        // Every board a 2ch reader made is restricted, so the row into them goes.
        XCTAssertFalse(app.buttons["User boards"].exists, "the user boards row was shown")
    }

    /// The board list's filter doubles as a "go to" field, which is the way
    /// round the directory.
    func testTypingARestrictedCodeSaysWhy() {
        let app = launchWithMatureOff()
        XCTAssertTrue(app.staticTexts["/a/"].waitForExistence(timeout: Self.networkTimeout))

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no filter field")
        field.tap()
        field.typeText("hc")

        XCTAssertTrue(
            app.staticTexts["go-to-restricted"].waitForExistence(timeout: 5)
                || app.otherElements["go-to-restricted"].waitForExistence(timeout: 5),
            "typing a restricted code offered no explanation"
        )
        XCTAssertFalse(app.buttons["go-to"].exists, "a restricted board was offered anyway")
    }

    func testTurningPostingOffTakesAwayTheWaysToWrite() {
        let app = launchApp(
            extraArguments: ["-posting.enabled", "NO"],
            pinsRestrictions: false
        )
        openDefaultBoard(app)

        XCTAssertFalse(
            app.buttons["New thread"].exists,
            "a new thread could still be started with posting off"
        )

        openThreadWithReplies(app, minimum: 5)
        XCTAssertFalse(app.buttons["Reply"].exists, "a reply could still be written")
    }
}
