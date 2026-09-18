import XCTest

/// The settings a reader changes while looking at the result, and the thread
/// gallery they open to find the pictures.
@MainActor
final class AppearanceAndGalleryUITests: LiveUITestCase {
    /// Picking an appearance changes the app there and then, rather than when
    /// the screen is next rebuilt.
    func testAppearanceAppliesImmediately() throws {
        let app = launchApp()
        openSettings(app)
        app.buttons["Appearance"].firstMatch.tap()

        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5), "the appearance picker is missing")

        let before = app.screenshot().image
        dark.tap()
        // Give the change one run loop and the animation a moment to finish.
        Thread.sleep(forTimeInterval: 1.5)
        let after = app.screenshot().image

        XCTAssertNotEqual(
            before.pngData(),
            after.pngData(),
            "the screen did not change when the appearance did"
        )

        app.buttons["Light"].tap()
    }

    /// The theme list offers real choices, and picking one takes effect.
    func testThemeListOffersSchemes() throws {
        let app = launchApp()
        openSettings(app)
        app.buttons["Appearance"].firstMatch.tap()
        app.buttons["Theme"].firstMatch.tap()

        XCTAssertTrue(
            app.navigationBars["Theme"].waitForExistence(timeout: 5),
            "the theme screen did not open"
        )
        for scheme in ["System", "Crimson", "Forest", "Amber"] {
            XCTAssertTrue(
                app.staticTexts[scheme].exists,
                "\(scheme) is not offered"
            )
        }
        // Midnight became the System scheme, and Solarized went with it.
        for gone in ["Midnight", "Solarized"] {
            XCTAssertFalse(app.staticTexts[gone].exists, "\(gone) should no longer be offered")
        }

        // From a known scheme: a failed run stops before its own reset, so the
        // next one would start on the very scheme it is about to pick and see
        // nothing change.
        app.staticTexts["System"].tap()
        Thread.sleep(forTimeInterval: 1.0)

        let before = app.screenshot().image
        app.staticTexts["Crimson"].tap()
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertNotEqual(
            before.pngData(),
            app.screenshot().image.pngData(),
            "picking a scheme changed nothing"
        )
        app.staticTexts["System"].tap()
    }

    /// The layout picked on a board is still in force after leaving it.
    func testBoardLayoutIsRemembered() throws {
        let app = launchApp()
        openDefaultBoard(app)

        app.navigationBars.buttons["View options"].tap()
        app.buttons["Grid"].tap()
        Thread.sleep(forTimeInterval: 1.0)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["/b/"].waitForExistence(timeout: 10),
            "did not return to the board list"
        )
        app.staticTexts["/b/"].tap()

        app.navigationBars.buttons["View options"].tap()
        let grid = app.buttons["Grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertTrue(
            grid.isSelected,
            "the board forgot the layout that was chosen for it"
        )

        // Leave the board as the other tests expect to find it.
        app.buttons["Cards"].tap()
    }

    /// The thread gallery lists every attachment and opens one.
    func testThreadGalleryOpensAnAttachment() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        app.navigationBars.buttons["Thread actions"].tap()
        let gallery = app.buttons["Gallery"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 5), "the gallery action is missing")
        gallery.tap()

        let grid = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'"))
        XCTAssertTrue(
            grid.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the gallery grid showed no attachments"
        )

        grid.firstMatch.tap()
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "tapping a thumbnail did not open the viewer"
        )
    }

    /// Closing a picture opened from the gallery comes back to the gallery.
    ///
    /// It used to drop the reader all the way back to the posts, so looking at
    /// three files meant opening the gallery three times.
    func testClosingAnAttachmentReturnsToTheGallery() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        app.navigationBars.buttons["Thread actions"].tap()
        let gallery = app.buttons["Gallery"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 5), "the gallery action is missing")
        gallery.tap()

        let grid = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'"))
        XCTAssertTrue(
            grid.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the gallery grid showed no attachments"
        )
        grid.firstMatch.tap()
        XCTAssertTrue(
            galleryCounter(app).waitForExistence(timeout: Self.networkTimeout),
            "tapping a thumbnail did not open the viewer"
        )

        app.buttons["Close"].firstMatch.tap()

        XCTAssertTrue(
            app.buttons["Done"].firstMatch.waitForExistence(timeout: 10),
            "closing a picture left the gallery as well"
        )
        XCTAssertTrue(
            grid.firstMatch.exists,
            "the gallery came back without its thumbnails"
        )

        // And the gallery itself still closes to the thread.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: 10),
            "closing the gallery did not return to the thread"
        )
    }

    /// Every icon the app ships with is offered, and they sit side by side on
    /// one row rather than taking a row of the screen each.
    func testIconPickerOffersEveryIconOnOneRow() throws {
        let app = launchApp()
        openSettings(app)
        app.buttons["Appearance"].firstMatch.tap()

        let tiles = ["app-icon-original", "app-icon-neechan", "app-icon-peace"]
            .map { app.buttons[$0] }

        XCTAssertTrue(
            tiles[0].waitForExistence(timeout: 5),
            "the icon picker is missing"
        )
        for (name, tile) in zip(tiles.indices, tiles) where !tile.exists {
            XCTFail("icon tile \(name) is missing")
        }

        attach(app, name: "07-icon-picker")

        // One row: same vertical centre, increasing horizontal position.
        let frames = tiles.map(\.frame)
        for frame in frames.dropFirst() {
            XCTAssertEqual(
                frame.midY, frames[0].midY, accuracy: 1,
                "the icon tiles are not on the same row"
            )
        }
        XCTAssertTrue(
            zip(frames, frames.dropFirst()).allSatisfy { $0.minX < $1.minX },
            "the icon tiles are not laid out left to right"
        )
    }

    private func openSettings(_ app: XCUIApplication) {
        switchToTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
}

/// The two size settings, checked by looking at what they are supposed to
/// change rather than at the slider that changes it.
@MainActor
final class ScaleSettingsUITests: LiveUITestCase {
    func testTextSizeChangesPostText() throws {
        try assertScaleChangesTheThread(identifier: "text-scale", needsAttachment: false)
    }

    func testThumbnailSizeChangesThumbnails() throws {
        try assertScaleChangesTheThread(identifier: "thumbnail-scale", needsAttachment: true)
    }

    /// Measures what a scale is meant to resize, at its smallest and at its
    /// largest.
    ///
    /// A thread is read full screen, so Settings is reached from outside one:
    /// the thread is opened, measured and left for each of the two sizes. The
    /// old version compared screenshots taken without leaving the thread, which
    /// the tab bar made possible and no longer is.
    private func assertScaleChangesTheThread(
        identifier: String,
        needsAttachment: Bool
    ) throws {
        let app = launchApp()

        // Preferences outlive the app, so an earlier run may have left this at
        // the maximum. Start from the smallest size, or raising it would change
        // nothing and the test would be measuring its own leftovers.
        adjustScale(app, identifier: identifier, to: 0)
        let small = try measureThread(app, needsAttachment: needsAttachment, fromHistory: false)

        adjustScale(app, identifier: identifier, to: 1.0)
        // Through History, so this is the same thread as the first pass. The
        // board's first row is a different thread within a minute on /b/.
        let large = try measureThread(app, needsAttachment: needsAttachment, fromHistory: true)

        XCTAssertEqual(
            small.postNum, large.postNum,
            "the two measurements are of different threads"
        )
        XCTAssertGreaterThan(
            large.size, small.size * 1.1,
            "\(identifier) did not change the size of what it names"
        )

        // Leave the shipped size behind for whatever runs next.
        adjustScale(app, identifier: identifier, to: 0.2)
    }

    /// Opens the first thread, measures the thing the scale resizes, and leaves.
    private func measureThread(
        _ app: XCUIApplication,
        needsAttachment: Bool,
        fromHistory: Bool
    ) throws -> (size: CGFloat, postNum: String) {
        if fromHistory {
            switchToTab(app, "History")
            let visited = app.staticTexts["/b/"].firstMatch
            XCTAssertTrue(
                visited.waitForExistence(timeout: 15),
                "the thread just read is not in history"
            )
            visited.tap()
            XCTAssertTrue(
                anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
                "the thread did not reopen from history"
            )
        } else {
            switchToTab(app, "Boards")
            if !replyCounts(app).firstMatch.waitForExistence(timeout: 5) {
                openDefaultBoard(app)
            }
            openFirstThread(app)
        }

        let postNum = anyPostNumber(app).label
        let size: CGFloat
        if needsAttachment {
            try scrollToAnAttachment(app)
            let thumbnail = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'"))
                .firstMatch
            size = thumbnail.frame.width
        } else {
            let body = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'post-body-'"))
                .firstMatch
            XCTAssertTrue(
                body.waitForExistence(timeout: Self.networkTimeout),
                "the thread drew no post text to measure"
            )
            size = body.frame.height
        }

        XCTAssertTrue(leaveThread(app), "the tabs did not come back after the thread")
        return (size, postNum)
    }

    /// Scrolls the thread until a thumbnail is on screen, since a scale that
    /// nothing visible uses would change nothing.
    private func scrollToAnAttachment(_ app: XCUIApplication) throws {
        let thumbnails = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'"))

        for _ in 0..<15 where !thumbnails.firstMatch.exists {
            app.scrollViews.firstMatch.swipeUp(velocity: .fast)
        }
        try XCTSkipUnless(
            thumbnails.firstMatch.waitForExistence(timeout: 10),
            "this thread has no attachments to size"
        )
    }

    private func adjustScale(_ app: XCUIApplication, identifier: String, to position: CGFloat) {
        switchToTab(app, "Settings")
        if !app.sliders[identifier].exists {
            app.buttons["Appearance"].firstMatch.tap()
        }
        let slider = app.sliders[identifier]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "\(identifier) is missing")
        slider.adjust(toNormalizedSliderPosition: position)
    }
}
