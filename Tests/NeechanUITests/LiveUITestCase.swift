import XCTest

/// Shared setup for the tests that drive the app against the live site.
///
/// Every one of them has to reach a board, a thread or an attachment first, and
/// each was doing it slightly differently. Gathering it here also fixes a flake:
/// a test running on its own could attach to an instance another test had left
/// running, and start somewhere other than the board list.
@MainActor
class LiveUITestCase: XCTestCase {
    /// How long to wait on anything that has to come off the network.
    static let networkTimeout: TimeInterval = 30

    override func setUp() async throws {
        continueAfterFailure = false
        // Never inherit another test's navigation state.
        XCUIApplication().terminate()
    }

    /// Launches the app at the board list.
    ///
    /// The language is pinned to English: simulators differ in locale, and a
    /// test that reads labels off the screen would otherwise pass on one device
    /// and fail on another for no reason to do with the app.
    /// - Parameters:
    ///   - extraArguments: passed straight through, which puts them in the app's
    ///     argument domain and so overrides anything it has saved. It is the
    ///     only way to pin a preference a previous test may have changed.
    ///   - pinsLanguage: keeps the app on the system language, which the tests
    ///     also pin to English. The app has a language of its own that outlives
    ///     a run, so without this one test switching it leaves every later test
    ///     reading Russian. The test that exercises the switch opts out.
    ///   - pinsRestrictions: keeps the content gates open. They outlive a run
    ///     like everything else here, so a test that closed one would leave
    ///     every later test looking at a directory with boards missing from it.
    ///     The tests about the gates opt out and pin their own.
    @discardableResult
    func launchApp(
        extraArguments: [String] = [],
        pinsLanguage: Bool = true,
        pinsImageboard: Bool = true,
        pinsRestrictions: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        // The app lock outlives a run the way the language does, and a run that
        // left it on would face every later test with a lock screen it cannot
        // answer: the device's prompt belongs to another process.
        app.launchArguments += ["-general.appLock", "NO"]
        // The imageboard outlives a run the way the language and the lock do.
        // Without this, one test that switched to 4chan would leave every later
        // test reading a different site's board directory. A test about 4chan
        // itself opts out and pins its own.
        if pinsImageboard {
            app.launchArguments += ["-imageboard", "dvach"]
            app.launchArguments += ["-defaultBoard", ""]
        }
        if pinsRestrictions {
            app.launchArguments += ["-restrictions.allowsMature", "YES"]
            app.launchArguments += ["-posting.enabled", "YES"]
        }
        if pinsLanguage {
            app.launchArguments += ["-general.language", "system"]
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    /// Answers the photo library prompt if one is on screen right now.
    ///
    /// Saving to Photos asks the first time on a fresh simulator, and the prompt
    /// belongs to Springboard rather than to the app, so `app.alerts` never sees
    /// it: the save simply appears to hang behind a dialog the test is not
    /// looking at. Written as a single glance rather than a wait, so a caller
    /// can fold it into a loop it is already running and never stall on it.
    @discardableResult
    func answerPhotoLibraryPromptIfPresent() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return true
            }
        }
        return false
    }

    /// Opens /b/, which is always present and always busy.
    func openDefaultBoard(_ app: XCUIApplication) {
        let board = app.staticTexts["/b/"]
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
    }

    /// Puts the board in the card layout.
    ///
    /// The layout is remembered per board, so a test that switched to the grid
    /// would otherwise leave every later test tapping thumbnails, which opens
    /// the media viewer instead of the thread.
    func useCardsLayout(_ app: XCUIApplication) {
        let options = app.navigationBars.buttons["View options"]
        guard options.waitForExistence(timeout: 10) else { return }
        options.tap()

        let cards = app.buttons["Cards"]
        if cards.waitForExistence(timeout: 5) {
            cards.tap()
        } else {
            // The menu opened onto something else; close it rather than leaving
            // it covering the board.
            app.tap()
        }
        _ = replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout)
    }

    /// Every thread card's reply count, which reads "42 replies".
    func replyCounts(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "thread-replies")
    }

    /// Opens the first thread on the board and waits for its posts.
    ///
    /// The count element sits inside the thread card, whose whole area is the
    /// tap target, so tapping it opens that thread.
    func openFirstThread(_ app: XCUIApplication) {
        replyCounts(app).firstMatch.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the thread's posts did not render"
        )
    }

    /// Opens a thread busy enough to contain a conversation.
    ///
    /// The first thread on a board is usually a pinned announcement with no
    /// replies, which is useless for anything about quoting or backlinks.
    func openThreadWithReplies(_ app: XCUIApplication, minimum: Int = 20) {
        var busiest: (element: XCUIElement, replies: Int)?

        for _ in 0..<8 {
            let counts = replyCounts(app)
            for index in 0..<counts.count {
                let element = counts.element(boundBy: index)
                guard element.exists, element.isHittable else { continue }
                guard let replies = Int(element.label.prefix { $0.isNumber }) else { continue }

                if replies >= minimum {
                    open(element, in: app)
                    return
                }
                // Remembered in case the board simply has nothing that busy
                // right now; a board's contents are not ours to control.
                if replies > (busiest?.replies ?? 0) {
                    busiest = (element, replies)
                }
            }
            app.swipeUp()
        }

        guard let busiest, busiest.replies > 0, busiest.element.isHittable else {
            XCTFail("no thread with any replies was on the board")
            return
        }
        open(busiest.element, in: app)
    }

    private func open(_ element: XCUIElement, in app: XCUIApplication) {
        element.tap()
        XCTAssertTrue(
            anyPostNumber(app).waitForExistence(timeout: Self.networkTimeout),
            "the thread's posts did not render"
        )
    }

    /// Opens the first thread and then its first attachment, leaving the
    /// gallery on screen.
    func openFirstAttachment(_ app: XCUIApplication) {
        openFirstThread(app)
        // Attachment thumbnails are the buttons inside the post cells.
        let thumbnail = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: Self.networkTimeout),
            "the thread had no attachment to open"
        )
        thumbnail.tap()
    }

    /// Any post header, which always carries a number sign.
    func anyPostNumber(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "\u{2116}"))
            .firstMatch
    }

    /// The gallery's position counter, such as "1 / 12".
    func galleryCounter(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label MATCHES %@", #"^\d+ / \d+$"#))
            .firstMatch
    }

    /// Waits for something to go away, which `waitForExistence` cannot express.
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Leaves a thread and waits for the tabs to come back.
    ///
    /// A thread is read full screen, so anything reached through a tab has to
    /// be reached from outside one.
    @discardableResult
    func leaveThread(_ app: XCUIApplication) -> Bool {
        app.buttons["BackButton"].firstMatch.tap()
        guard app.buttons["Boards"].firstMatch.waitForExistence(timeout: 15) else { return false }
        expandTabBar(app)
        return true
    }

    /// Opens the tab bar if it has minimised to a single pill.
    ///
    /// It collapses as the reader scrolls down a board, and the tabs other than
    /// the current one are then not there to tap at all.
    func expandTabBar(_ app: XCUIApplication) {
        let collapsed = app.descendants(matching: .button)
            .matching(NSPredicate(format: "value == %@", "Collapsed"))
            .firstMatch
        guard collapsed.exists else { return }
        collapsed.tap()
        _ = app.tabBars.buttons.element(boundBy: 1).waitForExistence(timeout: 5)
    }

    /// Switches tabs, expanding the bar first if it has minimised.
    func switchToTab(_ app: XCUIApplication, _ name: String) {
        expandTabBar(app)
        app.tabBars.buttons[name].tap()
    }

    func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
