import XCTest

/// The build meant for the App Store, seen from the outside.
///
/// Self-selecting rather than gated on a configuration: it asks the app which
/// build it is and skips when the answer is "the ordinary one". That way it is
/// harmless in the normal test run and meaningful when pointed at the variant
/// with `make test-one ONLY=NeechanUITests/AppStoreBuildUITests CONFIGURATION=AppStore`.
@MainActor
final class AppStoreBuildUITests: LiveUITestCase {
    /// Opens Restrictions, and says whether this is the App Store build.
    ///
    /// The tell is the age gate's footer, which says something different here
    /// because the switch means something different. It used to be the note
    /// under the posting switch, which no longer exists: posting is not a
    /// preference in any build any more.
    private func openRestrictions(_ app: XCUIApplication) throws -> Bool {
        switchToTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))

        let row = app.buttons["Restrictions"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Restrictions is not in Settings")
        row.tap()
        XCTAssertTrue(app.switches["mature-toggle"].waitForExistence(timeout: 10))

        return app.staticTexts["adult-gate-note-appstore"].exists
    }

    /// Launched without the usual pinning: pinning posting open with a launch
    /// argument is exactly what this build is supposed to ignore, which makes
    /// it the proof rather than a nuisance.
    func testTheRestrictionsScreenOffersNoPostingSwitch() throws {
        let app = launchApp(
            extraArguments: ["-posting.enabled", "YES", "-restrictions.allowsMature", "YES"],
            pinsRestrictions: false
        )
        try XCTSkipUnless(try openRestrictions(app), "not the App Store build")

        XCTAssertFalse(
            app.switches["posting-toggle"].exists,
            "posting is offered as a preference in the App Store build"
        )

        // The other two are ordinary preferences here, not locks.
        XCTAssertTrue(app.switches["nsfw-mode-toggle"].isEnabled)
        XCTAssertTrue(app.switches["mature-toggle"].isEnabled)

        attach(app, name: "appstore-restrictions")
    }

    // MARK: The agreement

    /// Shown before anything else, and not dismissible: an agreement the
    /// reader can walk past is not one they made.
    ///
    /// Pinned shut with a launch argument, which also fixes what this can
    /// check. An argument lives in `UserDefaults`' argument domain, which
    /// outranks anything the app writes, so tapping the button here cannot
    /// move the preference and the agreement cannot be got past — the same
    /// reason `RestrictionsUITests` drives the age gate through the screen
    /// instead of pinning it. What the button does is covered by
    /// `AppSettingsTests.agreeingSticks`, and the accepted path by the test
    /// below.
    func testTheAgreementBlocksTheFirstLaunch() throws {
        let app = launchApp(
            extraArguments: ["-general.agreedToTerms", "NO"],
            acceptsTerms: false
        )

        // Probed on the button rather than on the container around it: a
        // `VStack` carrying only an identifier is not an accessibility
        // element, so querying for it would skip a test that should have run.
        let accept = app.buttons["agreement-accept"]
        guard accept.waitForExistence(timeout: 15) else {
            throw XCTSkip("not the App Store build")
        }

        XCTAssertFalse(
            app.tabBars.firstMatch.exists,
            "the app was reachable without accepting the terms"
        )
        XCTAssertTrue(app.staticTexts["Age Restriction"].exists, "the age term is missing")
        XCTAssertTrue(app.staticTexts["Content Reporting (DMCA)"].exists, "the DMCA term is missing")
        // Promised because it is kept: any post can be reported from its own
        // menu, and anything can be hidden. A term the app does not keep is
        // worse than one it never made, so this is what fails if the report
        // action is ever taken away again.
        XCTAssertTrue(
            app.staticTexts["Reporting & Blocking"].exists,
            "the agreement no longer mentions reporting, which the app offers"
        )

        attach(app, name: "appstore-agreement")
    }

    /// Accepted once, never asked again — and still readable, because terms
    /// nobody can re-read are terms nobody agreed to either.
    func testTheAgreementIsNotAskedTwiceAndStaysReadable() throws {
        let app = launchApp()
        try XCTSkipUnless(try openRestrictions(app), "not the App Store build")

        XCTAssertFalse(
            app.buttons["agreement-accept"].exists,
            "the agreement was asked again after being accepted"
        )

        switchToTab(app, "Settings")
        app.buttons["settings-info.circle"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["about-terms"].waitForExistence(timeout: 10),
            "the terms could not be re-read from About"
        )
        app.buttons["about-terms"].tap()
        XCTAssertTrue(
            app.staticTexts["Age Restriction"].waitForExistence(timeout: 10),
            "the terms did not open"
        )
        XCTAssertFalse(
            app.buttons["agreement-accept"].exists,
            "the copy in About asks to be agreed to again"
        )
    }

    /// The point of the whole variant: no way to write, anywhere.
    func testAThreadOffersNoWayToPost() throws {
        let app = launchApp(pinsRestrictions: false)
        try XCTSkipUnless(try openRestrictions(app), "not the App Store build")

        switchToTab(app, "Boards")
        // /a/, not the usual /b/: this build lists only anime, manga and
        // comics, and /b/ is not among them.
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
