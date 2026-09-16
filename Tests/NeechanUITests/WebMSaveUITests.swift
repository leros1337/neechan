import XCTest

/// Saving a video finishes, whichever container it arrived in.
///
/// Photos refuses a WebM outright — `PHPhotosErrorDomain 3302` — so before the
/// converter that failed with an alert full of error codes. An MP4 needs no
/// conversion and takes the short path straight to Photos; both end at the same
/// place, which is also where the save haptic is played from.
@MainActor
final class WebMSaveUITests: LiveUITestCase {
    func testSavingAWebMConvertsItAndSucceeds() throws {
        let app = launchApp(extraArguments: ["-media.convertWebM", "YES"])
        openDefaultBoard(app)
        try openVideo(app, fileExtension: "webm")

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

    /// The common case: boards carry far more MP4s than WebMs, and an MP4 skips
    /// the converter, so this covers the short path to Photos that the WebM test
    /// never reaches.
    func testSavingAnMP4Succeeds() throws {
        let app = launchApp()
        openDefaultBoard(app)
        try openVideo(app, fileExtension: "mp4")

        app.buttons["Save"].firstMatch.tap()

        let capsule = app.descendants(matching: .any)
            .matching(identifier: "transfer-capsule")
            .firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 20), "saving said nothing at all")

        let saved = waitForSaved(app)
        if !saved { attach(app, name: "22-mp4-save-stuck") }
        XCTAssertTrue(saved, "saving an MP4 did not finish")
        XCTAssertFalse(
            app.alerts.firstMatch.exists,
            "saving reported a failure: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )

        attach(app, name: "22-mp4-saved")
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
            // The permission prompt sits in front of the app on a fresh
            // simulator, and nothing in `app` can see it.
            answerPhotoLibraryPromptIfPresent()
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

    /// Opens the first attachment of a given format in the viewer.
    private func openVideo(_ app: XCUIApplication, fileExtension: String) throws {
        // The grid shows every thread's thumbnail, so a given format turns up
        // far sooner than it does one card at a time.
        app.navigationBars.buttons["View options"].tap()
        if app.buttons["Grid"].waitForExistence(timeout: 5) {
            app.buttons["Grid"].tap()
        }

        let thumbnail = app.descendants(matching: .any)
            .matching(identifier: "attachment-\(fileExtension)")
            .firstMatch
        var scrolls = 0
        while !thumbnail.exists, scrolls < 10 {
            app.swipeUp()
            scrolls += 1
        }
        try XCTSkipUnless(
            thumbnail.exists, "no .\(fileExtension) was on the board right now"
        )
        thumbnail.tap()
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the viewer did not open"
        )
    }
}
