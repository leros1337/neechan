import XCTest

/// The build meant for the App Store, seen from the outside.
///
/// Self-selecting rather than gated on a configuration: it asks the app which
/// build it is and skips when the answer is "the ordinary one". That way it is
/// harmless in the normal test run and meaningful when pointed at the variant
/// with `make test-one ONLY=NeechanUITests/AppStoreBuildUITests CONFIGURATION=AppStore`.
@MainActor
final class AppStoreBuildUITests: LiveUITestCase {
    /// Opens Restrictions, and says whether this build fixes posting.
    private func openRestrictions(_ app: XCUIApplication) throws -> Bool {
        switchToTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))

        let row = app.buttons["Restrictions"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Restrictions is not in Settings")
        row.tap()
        XCTAssertTrue(app.switches["posting-toggle"].waitForExistence(timeout: 10))

        return app.staticTexts["posting-fixed-note"].exists
    }

    /// Launched without the usual pinning: pinning posting open with a launch
    /// argument is exactly what this build is supposed to ignore, which makes
    /// it the proof rather than a nuisance.
    func testPostingIsFixedOffAndTheOtherTwoAreNot() throws {
        let app = launchApp(
            extraArguments: ["-posting.enabled", "YES", "-restrictions.allowsMature", "YES"],
            pinsRestrictions: false
        )
        try XCTSkipUnless(try openRestrictions(app), "not the App Store build")

        let posting = app.switches["posting-toggle"]
        XCTAssertFalse(posting.isEnabled, "posting could still be switched on")
        XCTAssertEqual(posting.value as? String, "0", "a launch argument turned posting on")

        // The other two are ordinary preferences here, not locks.
        XCTAssertTrue(app.switches["nsfw-mode-toggle"].isEnabled)
        XCTAssertTrue(app.switches["mature-toggle"].isEnabled)

        attach(app, name: "appstore-restrictions")
    }

    /// The point of the whole variant: no way to write, anywhere.
    func testAThreadOffersNoWayToPost() throws {
        let app = launchApp(pinsRestrictions: false)
        try XCTSkipUnless(try openRestrictions(app), "not the App Store build")

        switchToTab(app, "Boards")
        // /a/, not the usual /b/: this build starts with Mature 21+ off, and
        // /b/ is one of the boards that hides. (Finding that out by watching
        // `openDefaultBoard` fail is a decent proof the gate works.)
        let board = app.staticTexts["/a/"]
        XCTAssertTrue(
            board.waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )
        board.tap()
        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the board's threads did not load"
        )
        useCardsLayout(app)

        XCTAssertFalse(app.buttons["New thread"].exists, "a new thread could be started")

        openThreadWithReplies(app, minimum: 5)
        XCTAssertFalse(app.buttons["Reply"].exists, "a reply could be written")
    }
}
