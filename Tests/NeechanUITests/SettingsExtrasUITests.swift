import XCTest

/// The things added to Settings and to the board list, and the toast a thread
/// shows after a refresh.
@MainActor
final class SettingsExtrasUITests: LiveUITestCase {
    /// Refreshing says what it found, whether or not anything arrived.
    func testRefreshAnnouncesWhatItFound() throws {
        let app = launchApp()
        openDefaultBoard(app)
        openFirstThread(app)

        app.navigationBars.buttons["Thread actions"].tap()
        app.buttons["Reload"].firstMatch.tap()

        let toast = app.descendants(matching: .any)
            .matching(identifier: "refresh-toast")
            .firstMatch
        XCTAssertTrue(
            toast.waitForExistence(timeout: Self.networkTimeout),
            "a refresh said nothing at all"
        )
    }

    /// The user boards have their own list, reachable from the directory.
    func testUserBoardsOpenFromTheBoardList() throws {
        let app = launchApp()
        let entry = app.buttons["User boards"].firstMatch
        XCTAssertTrue(
            entry.waitForExistence(timeout: Self.networkTimeout),
            "the board list does not offer user boards"
        )
        entry.tap()

        XCTAssertTrue(
            app.navigationBars["User boards"].waitForExistence(timeout: 10),
            "the user boards screen did not open"
        )
        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the user boards list is empty"
        )
    }

    /// Statistics counts what the reader did, and sits under Saved threads.
    func testStatisticsCountsThreadsOpened() throws {
        let app = launchApp()
        openSettings(app)
        app.buttons["Statistics"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))

        app.buttons["Reset statistics"].tap()
        app.buttons["Reset"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.5)

        switchToTab(app, "Boards")
        openDefaultBoard(app)
        openFirstThread(app)

        // A thread is read full screen, so the tabs are reached from outside it.
        XCTAssertTrue(leaveThread(app), "the tabs did not come back after the thread")
        switchToTab(app, "Settings")
        let threadsOpened = app.staticTexts["Threads opened"]
        XCTAssertTrue(threadsOpened.waitForExistence(timeout: 5), "the statistics screen closed")

        // The value sits beside its label in the same row.
        let row = app.cells.containing(.staticText, identifier: "Threads opened").firstMatch
        XCTAssertTrue(
            row.staticTexts["1"].waitForExistence(timeout: 5),
            "opening a thread was not counted"
        )
    }

    /// Choosing a language changes the app's own text at once.
    func testLanguageSwitcherAppliesImmediately() throws {
        continueAfterFailure = true
        // The one test that must be able to change the app's language, so it
        // cannot have it pinned.
        let app = launchApp(pinsLanguage: false)

        // The language outlives the run, so it goes back to English whatever
        // happens in between.
        addTeardownBlock { @MainActor in
            // By label in both languages rather than by position: this runs
            // with the app in Russian, and a tab's index moves whenever the
            // bar's order changes.
            self.openSettingsTab(app)
            app.buttons["settings-gearshape"].firstMatch.tap()
            let picker = app.buttons["language-picker"].firstMatch
            if picker.waitForExistence(timeout: 5) {
                picker.tap()
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == 'English'"))
                    .firstMatch
                    .tap()
            }
        }

        openSettings(app)
        app.buttons["settings-gearshape"].firstMatch.tap()

        // A picker in a form is a row; its title is a label inside it, which is
        // not itself tappable, so the row is what gets the tap.
        let picker = app.buttons["language-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the language picker is missing")
        picker.tap()
        let russian = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Русский'"))
            .firstMatch
        XCTAssertTrue(russian.waitForExistence(timeout: 5), "Russian is not offered")
        russian.tap()

        XCTAssertTrue(
            app.staticTexts["Язык"].waitForExistence(timeout: 5),
            "the app did not switch to Russian"
        )

        // The rows of the Settings list itself. They were built from a resource
        // that resolves against the app bundle, which holds no strings, so they
        // stayed English while the screen around them translated.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Общие"].waitForExistence(timeout: 5),
            "the Settings rows did not translate"
        )
        for row in ["Форум", "Оформление", "Содержимое", "Медиа", "О программе"] {
            XCTAssertTrue(app.staticTexts[row].exists, "\(row) did not translate")
        }

        // A string built in code rather than by SwiftUI. It follows the device's
        // language unless the app publishes its own choice.
        app.buttons["settings-paintpalette"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Размер текста"].waitForExistence(timeout: 5),
            "the size sliders did not translate"
        )
    }

    private func openSettings(_ app: XCUIApplication) {
        openSettingsTab(app)
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5)
                || app.navigationBars["Настройки"].exists,
            "the Settings tab did not open"
        )
    }

    /// Taps the Settings tab in whichever language the app is drawing itself.
    ///
    /// This suite changes the language, and the change outlives the run: a test
    /// that failed before restoring English leaves the next one looking at a
    /// Russian tab bar. Matching both labels is what lets it recover by itself.
    fileprivate func openSettingsTab(_ app: XCUIApplication) {
        expandTabBar(app)
        app.tabBars.buttons
            .matching(NSPredicate(format: "label IN {'Settings', 'Настройки'}"))
            .firstMatch
            .tap()
    }
}
