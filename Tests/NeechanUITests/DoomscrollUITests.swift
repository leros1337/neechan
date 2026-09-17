import XCTest

/// A thread's videos, watched as a feed.
///
/// Against the live sites, because the point of this mode is that clips decode
/// and play, and nothing offline can show that. Written against the requirement
/// rather than a particular thread: boards turn over, and a test that names
/// today's front page is a test that fails tomorrow for no reason.
///
/// Three things are deliberately not asserted here. That only one decoder is
/// alive is a property of a view's lifetime with no handle to grab. That
/// warming shortened a wait is a stopwatch, not an assertion. And looping is
/// covered by `VideoLoopingUITests`, which drives the engine itself — this mode
/// has no scrubber to seek to the end with, so the unit test that it always
/// *asks* to loop is the honest coverage here.
@MainActor
final class DoomscrollUITests: LiveUITestCase {
    /// The mode says what the player is doing, since it has no transport whose
    /// label could prove a clip decoded.
    private func status(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "doomscroll-status").firstMatch
    }

    private func waitForPlaying(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status(app).value as? String == "playing" { return true }
            if status(app).value as? String == "failed" { return false }
            usleep(300_000)
        }
        return false
    }

    /// The number of clips the feed says it holds, from its `3 / 12` counter.
    private func clipCount(_ app: XCUIApplication) -> Int? {
        let position = app.staticTexts["doomscroll-position"]
        guard position.waitForExistence(timeout: 15) else { return nil }
        return Int(position.label.split(separator: "/").last?
            .trimmingCharacters(in: .whitespaces) ?? "")
    }

    /// Opens a thread carrying at least `minimum` videos, and leaves the feed on
    /// screen.
    ///
    /// Selection is done on the feed's own counter rather than on anything the
    /// board shows: a thread card reports how many *files* it has, and most of
    /// those are pictures. Opening the feed and reading how many clips it found
    /// is the only honest test of "this thread has enough video in it", and it
    /// costs one extra tap.
    ///
    /// The menu entry's `isEnabled` is deliberately not consulted. What matters
    /// is whether the feed opens with clips in it, and asking that directly
    /// cannot be wrong about how SwiftUI reports a disabled menu item.
    @discardableResult
    private func openDoomscroll(
        _ app: XCUIApplication,
        minimumClips minimum: Int = 3
    ) throws -> Int {
        openDefaultBoard(app)

        for index in 0..<14 {
            let counts = replyCounts(app)
            if counts.count <= index {
                app.swipeUp(velocity: .fast)
                continue
            }
            let card = counts.element(boundBy: index)
            guard card.exists, card.isHittable else { continue }

            card.tap()
            guard anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout) else {
                _ = leaveThread(app)
                continue
            }

            if let clips = openFeedIfItHasClips(app, minimum: minimum) {
                return clips
            }
            _ = leaveThread(app)
        }

        throw XCTSkip("no thread with \(minimum) videos was on the board right now")
    }

    /// Opens the feed from the thread on screen, keeping it only if it holds
    /// enough clips. Returns how many, or nil when this thread will not do.
    private func openFeedIfItHasClips(_ app: XCUIApplication, minimum: Int) -> Int? {
        let menu = app.navigationBars.buttons["Thread actions"].firstMatch
        guard menu.waitForExistence(timeout: 15) else { return nil }
        menu.tap()

        let entry = app.buttons["doomscroll"].firstMatch
        guard entry.waitForExistence(timeout: 5) else {
            XCTFail("Doomscroll is not in the thread menu")
            return nil
        }
        guard entry.isHittable else {
            // A thread with no video at all: the entry is there but dead.
            app.tap()
            return nil
        }
        entry.tap()

        guard app.buttons["doomscroll-sound"].waitForExistence(timeout: 15) else {
            // The menu closed without opening anything, which is what a
            // disabled entry does.
            return nil
        }
        guard let clips = clipCount(app), clips >= minimum else {
            app.buttons["Close"].firstMatch.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            return nil
        }
        return clips
    }

    func testTheFeedOpensAndPlays() throws {
        let app = launchApp()
        let clips = try openDoomscroll(app)
        XCTAssertGreaterThanOrEqual(clips, 3, "the feed was opened on too thin a thread")

        XCTAssertTrue(
            app.buttons["doomscroll-sound"].waitForExistence(timeout: 10),
            "the feed did not open"
        )
        XCTAssertTrue(waitForPlaying(app), "the first clip never started playing")
        attach(app, name: "doomscroll-playing")
    }

    /// Sound off at the start is the whole reason this is safe to open.
    func testItStartsSilentAndTheChoiceCoversEveryClip() throws {
        let app = launchApp()
        try openDoomscroll(app)

        let sound = app.buttons["doomscroll-sound"]
        XCTAssertTrue(sound.waitForExistence(timeout: 10))
        XCTAssertEqual(sound.value as? String, "Off", "the feed opened making noise")
        XCTAssertTrue(waitForPlaying(app))

        sound.tap()
        XCTAssertEqual(sound.value as? String, "On")

        // One mute for the mode, not one per clip: paging must not silence it
        // again.
        app.swipeUp(velocity: .fast)
        XCTAssertTrue(waitForPlaying(app), "the next clip never played")
        XCTAssertEqual(sound.value as? String, "On", "the sound was reset by paging")
    }

    /// Paging stops what was playing and starts what arrived.
    func testPagingMovesToTheNextClip() throws {
        let app = launchApp()
        try openDoomscroll(app)

        let position = app.staticTexts["doomscroll-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10), "no position counter")
        XCTAssertTrue(waitForPlaying(app))

        let first = position.label
        app.swipeUp(velocity: .fast)
        XCTAssertTrue(
            waitForPlaying(app),
            "the clip paged to never started, so the feed stops at the first swipe"
        )
        XCTAssertNotEqual(position.label, first, "paging did not move to another clip")
        attach(app, name: "doomscroll-second-clip")
    }

    /// Saving from the feed, which is where four separate things went wrong:
    /// the capsule sat at nothing, then said "Saved" forever, nothing buzzed,
    /// and it was not obvious a WebM was being converted at all.
    ///
    /// The clip has always been streamed by the time Save is tapped, so its
    /// pieces are on disk and the save fills in the rest — the path that used
    /// to report no progress whatsoever.
    func testSavingAClipReportsProgressAndThenClearsItself() throws {
        let app = launchApp(extraArguments: ["-media.convertWebM", "YES"])
        try openDoomscroll(app)
        XCTAssertTrue(waitForPlaying(app), "nothing was playing, so nothing was cached to save")

        app.buttons["doomscroll-save"].tap()

        let capsule = app.descendants(matching: .any)
            .matching(identifier: "transfer-capsule")
            .firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 20), "saving showed no capsule at all")
        attach(app, name: "doomscroll-saving")

        XCTAssertTrue(sawSaveFinish(app, capsule: capsule), "the save never finished")

        // The whole of the second bug: it used to stay on screen until the feed
        // was closed.
        XCTAssertTrue(
            waitForDisappearance(of: capsule, timeout: 20),
            "the capsule stayed on screen after the save finished"
        )
        // Still on the clip it was saving, rather than having been dismissed.
        XCTAssertTrue(app.buttons["doomscroll-sound"].exists)
    }

    /// Waits for the capsule to say the save is done, answering the photo
    /// prompt and failing on an error alert.
    private func sawSaveFinish(_ app: XCUIApplication, capsule: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            answerPhotoLibraryPromptIfPresent()
            if app.alerts.firstMatch.exists {
                XCTFail("saving failed: \(app.alerts.firstMatch.label)")
                return false
            }
            guard capsule.exists else { return true }
            if capsule.label.contains("Saved") { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
