import XCTest

/// Saving a WebM produces something the phone can actually play.
///
/// Photos refuses a WebM outright — `PHPhotosErrorDomain 3302` — so before the
/// converter this failed with an alert full of error codes.
@MainActor
final class WebMSaveUITests: LiveUITestCase {
    func testSavingAWebMConvertsItAndSucceeds() throws {
        let app = launchApp(extraArguments: ["-media.convertWebM", "YES"])
        openDefaultBoard(app)
        try openAWebM(app)

        app.buttons["Save"].firstMatch.tap()

        let capsule = app.descendants(matching: .any)
            .matching(identifier: "transfer-capsule")
            .firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 20), "saving said nothing at all")

        // The end state is what matters: the alert only appears on failure, and
        // its text is what used to carry the Photos rejection.
        XCTAssertTrue(waitForSaved(app), "saving a WebM did not finish")
        XCTAssertFalse(
            app.alerts.firstMatch.exists,
            "saving reported a failure: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )

        attach(app, name: "21-webm-saved")
    }

    /// Waits for the capsule to reach its finished state.
    private func waitForSaved(_ app: XCUIApplication) -> Bool {
        // Bounded: a board clip can be tens of megabytes, but a wait longer
        // than this is a hang worth failing on rather than sitting through.
        let deadline = Date().addingTimeInterval(120)
        let capsule = app.descendants(matching: .any)
            .matching(identifier: "transfer-capsule")
            .firstMatch
        while Date() < deadline {
            if app.alerts.firstMatch.exists { return false }
            // The capsule clears itself a couple of seconds after finishing, so
            // its going away without an alert is success. Asked first, because
            // reading the label of an element that is gone throws.
            guard capsule.exists else { return true }
            if capsule.label.contains("Saved") { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func openAWebM(_ app: XCUIApplication) throws {
        // The grid shows every thread's thumbnail, so a given format turns up
        // far sooner than it does one card at a time.
        app.navigationBars.buttons["View options"].tap()
        if app.buttons["Grid"].waitForExistence(timeout: 5) {
            app.buttons["Grid"].tap()
        }

        let thumbnail = app.descendants(matching: .any)
            .matching(identifier: "attachment-webm")
            .firstMatch
        var scrolls = 0
        while !thumbnail.exists, scrolls < 10 {
            app.swipeUp()
            scrolls += 1
        }
        try XCTSkipUnless(thumbnail.exists, "no WebM was on the board right now")
        thumbnail.tap()
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the viewer did not open"
        )
    }
}
