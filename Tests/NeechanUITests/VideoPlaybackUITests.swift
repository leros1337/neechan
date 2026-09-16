import XCTest

/// WebM is the reason this app ships an FFmpeg build: AVFoundation cannot open
/// VP8 or VP9 at all. These walk the live board until they find one and check
/// that it actually starts playing, which no unit test can prove.
@MainActor
final class VideoPlaybackUITests: LiveUITestCase {
    func testAWebMDecodesAndPlays() throws {
        try playFirstVideo(withExtension: "webm", screenshotNamed: "06-webm")
    }

    func testAnMP4DecodesAndPlays() throws {
        try playFirstVideo(withExtension: "mp4", screenshotNamed: "07-mp4")
    }

    /// Finds a thread whose opening post carries a file of this format and plays
    /// it straight from the board.
    ///
    /// Roughly a fifth of threads carry video and the split between formats
    /// varies, so the board is scrolled before giving up, and the test skips
    /// rather than fails when the board simply has none right now.
    func testLoopingIsOffUntilTheReaderTurnsItOn() throws {
        let app = launchApp()
        openDefaultBoard(app)
        try openAnyVideo(app)

        let loop = app.buttons["Loop"].firstMatch
        XCTAssertTrue(loop.waitForExistence(timeout: Self.networkTimeout), "no loop control")

        // A clip plays once unless asked otherwise, so the control starts off.
        XCTAssertEqual(loop.value as? String, "Off", "looping should start off")
        loop.tap()
        XCTAssertEqual(loop.value as? String, "On", "tapping loop should turn it on")
        loop.tap()
        XCTAssertEqual(loop.value as? String, "Off", "tapping loop again should turn it off")

        attach(app, name: "16-loop")
    }

    /// Opens whichever video format the board happens to be showing.
    private func openAnyVideo(_ app: XCUIApplication) throws {
        for fileExtension in ["webm", "mp4"] {
            let thumbnail = app.descendants(matching: .any)
                .matching(identifier: "attachment-\(fileExtension)")
                .firstMatch
            var scrolls = 0
            while !thumbnail.exists, scrolls < 8 {
                app.swipeUp()
                scrolls += 1
            }
            if thumbnail.exists {
                thumbnail.tap()
                XCTAssertTrue(
                    galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
                    "the player did not open"
                )
                return
            }
        }
        throw XCTSkip("no video was on the board right now")
    }

    private func playFirstVideo(
        withExtension fileExtension: String,
        screenshotNamed name: String
    ) throws {
        let app = launchApp()
        openDefaultBoard(app)

        // The grid shows every thread's thumbnail, so a given format turns up
        // far more often than it does one card at a time.
        app.navigationBars.buttons["View options"].tap()
        if app.buttons["Grid"].waitForExistence(timeout: 5) {
            app.buttons["Grid"].tap()
        }

        let thumbnail = app.descendants(matching: .any)
            .matching(identifier: "attachment-\(fileExtension)")
            .firstMatch
        var scrolls = 0
        while !thumbnail.exists, scrolls < 20 {
            app.scrollViews.firstMatch.swipeUp(velocity: .fast)
            scrolls += 1
        }
        try XCTSkipUnless(
            thumbnail.waitForExistence(timeout: 10),
            "no thread with a .\(fileExtension) file was on the board right now"
        )

        // Tapping a thumbnail opens the media rather than the thread.
        thumbnail.tap()
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "tapping a video thumbnail did not open the player"
        )

        // Playback starting flips the transport button from Play to Pause, which
        // is the real proof the file was demuxed and decoded.
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: 60),
            "the .\(fileExtension) never started playing"
        )
        attach(app, name: name)
    }
}

/// Looping, checked by letting a clip actually reach its end.
///
/// The control's own state is covered elsewhere; this is about what happens
/// when the last frame goes past.
@MainActor
final class VideoLoopingUITests: LiveUITestCase {
    /// How long to allow a clip to run out after seeking to its end.
    private let endTimeout: TimeInterval = 40

    func testALoopingClipStartsAgainWhenItEnds() throws {
        let app = launchApp()
        openDefaultBoard(app)
        try openAnyVideo(app)

        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: Self.networkTimeout),
            "the clip never started playing"
        )

        // First with looping off, which also proves the clip is short enough to
        // run out inside this test.
        try seekNearTheEnd(app)
        try XCTSkipUnless(
            app.buttons["Play"].waitForExistence(timeout: endTimeout),
            "this clip is too long to reach its end here"
        )

        // Play it again, this time with looping on.
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20), "it did not play again")

        let loop = app.buttons["Loop"].firstMatch
        XCTAssertTrue(loop.waitForExistence(timeout: 10), "no loop control")
        if loop.value as? String != "On" { loop.tap() }
        XCTAssertEqual(loop.value as? String, "On")

        try seekNearTheEnd(app)

        // The position going back to the start is the only proof the clip really
        // played again. Asserting that it never stops is not enough: a clip can
        // sit on its last frame with the transport still reading Pause, which is
        // exactly what the engine's own loop flag used to do.
        XCTAssertTrue(
            waitForPositionToRestart(app),
            "the clip stopped at the end instead of starting again"
        )
        XCTAssertTrue(app.buttons["Pause"].exists, "it restarted but is not playing")

        attach(app, name: "17-looping")
    }

    /// Waits for the scrubber to report a position back near the beginning.
    ///
    /// The scrubber says "0:03 / 0:49", so the two halves can be compared.
    private func waitForPositionToRestart(_ app: XCUIApplication) -> Bool {
        let scrubber = app.descendants(matching: .any)
            .matching(identifier: "playback-scrubber")
            .firstMatch
        let deadline = Date().addingTimeInterval(endTimeout)

        while Date() < deadline {
            if let value = scrubber.value as? String,
               let (current, total) = Self.times(in: value),
               total > 0, current < total / 2 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Reads "0:03 / 0:49" as seconds.
    static func times(in label: String) -> (current: Int, total: Int)? {
        let halves = label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard halves.count == 2 else { return nil }

        func seconds(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard !parts.isEmpty else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        guard let current = seconds(halves[0]), let total = seconds(halves[1]) else { return nil }
        return (current, total)
    }

    /// Drags the scrubber to just before the last frame.
    private func seekNearTheEnd(_ app: XCUIApplication) throws {
        let scrubber = app.descendants(matching: .any)
            .matching(identifier: "playback-scrubber")
            .firstMatch
        try XCTSkipUnless(
            scrubber.waitForExistence(timeout: 20),
            "this clip reports no duration, so it cannot be seeked"
        )
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    }

    /// Opens whichever video the board is showing.
    ///
    /// The grid shows every thread's thumbnail at once, so a video turns up in
    /// a screen or two rather than after a dozen swipes through cards.
    private func openAnyVideo(_ app: XCUIApplication) throws {
        useGridLayout(app)

        let videos = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'attachment-webm' OR identifier == 'attachment-mp4'"))

        var scrolls = 0
        while !videos.firstMatch.exists, scrolls < 20 {
            app.scrollViews.firstMatch.swipeUp(velocity: .fast)
            scrolls += 1
        }
        try XCTSkipUnless(
            videos.firstMatch.waitForExistence(timeout: 15),
            "no video was on the board right now"
        )

        videos.firstMatch.tap()
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "the player did not open"
        )
    }

    private func useGridLayout(_ app: XCUIApplication) {
        app.navigationBars.buttons["View options"].tap()
        let grid = app.buttons["Grid"]
        if grid.waitForExistence(timeout: 5) { grid.tap() }
    }
}
