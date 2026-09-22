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

    func testTheRestrictionsScreenHoldsBothControls() {
        let app = launchApp()
        openSettings(app)

        let row = app.buttons["Restrictions"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Restrictions is not in Settings")
        row.tap()

        for identifier in ["nsfw-mode-toggle", "mature-toggle"] {
            XCTAssertTrue(
                app.switches[identifier].waitForExistence(timeout: 5),
                "\(identifier) is missing"
            )
        }
        // Posting is not a preference in any build: on everywhere but the App
        // Store variant, which offers no switch either.
        XCTAssertFalse(
            app.switches["posting-toggle"].exists,
            "posting is still offered as a preference"
        )
        // The gate ships open and NSFW mode ships closed.
        XCTAssertEqual(app.switches["mature-toggle"].value as? String, "1")
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

    /// Until the reader says they are 18, a link off the imageboard leaves for
    /// Safari rather than being followed inside the app, on a surface this app
    /// answers for. The switch that would say otherwise is disabled while the
    /// gate is shut, and its footer says where links go instead.
    ///
    /// Driven through the screen for the same reason as the test above: a
    /// pinned preference cannot be moved at all, and this one has to move
    /// twice. Starts from whatever is stored and leaves the gate open, as the
    /// rest of the suite expects to find it.
    func testTheInAppBrowserWaitsForTheAgeGate() {
        let app = launchApp(pinsRestrictions: false)
        openSettings(app)
        app.buttons["Restrictions"].firstMatch.tap()

        let mature = app.switches["mature-toggle"]
        XCTAssertTrue(mature.waitForExistence(timeout: 10), "the 18+ toggle is missing")
        if mature.value as? String == "0" {
            confirmAge(in: app, toggle: mature)
        }
        XCTAssertEqual(mature.value as? String, "1", "could not reach a known starting state")

        // Shutting the gate takes the browser preference with it.
        flip(mature)
        XCTAssertEqual(mature.value as? String, "0", "the gate did not close")

        let browser = app.switches["internal-browser-toggle"]
        backToSettings(app)
        openGeneral(app)
        XCTAssertTrue(browser.waitForExistence(timeout: 10), "the General screen did not open")
        XCTAssertFalse(
            browser.isEnabled,
            "links could be made to open in the app while the gate was shut"
        )

        // Opening it again hands the preference back.
        backToSettings(app)
        app.buttons["Restrictions"].firstMatch.tap()
        confirmAge(in: app, toggle: mature)
        XCTAssertEqual(mature.value as? String, "1", "the gate did not reopen")

        backToSettings(app)
        openGeneral(app)
        XCTAssertTrue(browser.waitForExistence(timeout: 10), "General did not come back")
        XCTAssertTrue(
            browser.isEnabled,
            "confirming the age did not give the browser preference back"
        )
    }

    /// Back out of a pushed settings screen onto the list it came from.
    private func backToSettings(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back to Settings")
        back.tap()
        XCTAssertTrue(
            app.buttons["Restrictions"].firstMatch.waitForExistence(timeout: 10),
            "did not land back on the settings list"
        )
    }

    private func openGeneral(_ app: XCUIApplication) {
        let row = app.buttons["General"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "General is not in Settings")
        row.tap()
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
        alert.buttons["I am 18 or older"].tap()
    }

    /// The age gate no longer empties the directory. A board that vanished was
    /// a board the reader went hunting for; it is listed and refused at the
    /// door instead, where the refusal can say why.
    func testTheAgeGateLeavesTheDirectoryAlone() {
        let app = launchWithMatureOff()

        XCTAssertTrue(
            app.staticTexts["/a/"].waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )
        XCTAssertTrue(app.staticTexts["/b/"].exists, "the age gate hid /b/ from the list")
    }

    /// The gate itself, on the way in rather than on the way out.
    func testOpeningAnAdultBoardOffersTheWayThrough() {
        let app = launchWithMatureOff()
        XCTAssertTrue(app.staticTexts["/b/"].waitForExistence(timeout: Self.networkTimeout))

        // Marked as gated rather than merely refusing the tap: `Router.push`
        // says no silently, which from the reader's side is a row that does
        // nothing at all.
        let gated = app.buttons["board-gated-b"]
        XCTAssertTrue(gated.waitForExistence(timeout: 10), "/b/ was not marked as gated")

        gated.tap()
        XCTAssertTrue(
            app.switches["mature-toggle"].waitForExistence(timeout: 10),
            "tapping an adult board did not lead to the age gate"
        )
        XCTAssertEqual(
            app.switches["mature-toggle"].value as? String, "0",
            "the gate was not still shut"
        )
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

        let refusal = app.buttons["go-to-restricted"]
        XCTAssertTrue(
            refusal.waitForExistence(timeout: 5),
            "typing a restricted code offered no explanation"
        )
        XCTAssertFalse(app.buttons["go-to"].exists, "a restricted board was offered anyway")

        // The explanation is also the way through.
        refusal.tap()
        XCTAssertTrue(
            app.switches["mature-toggle"].waitForExistence(timeout: 10),
            "the refusal did not lead to the age gate"
        )
    }
}
