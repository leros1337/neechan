import XCTest

/// Posts to the live site.
///
/// This writes a real post to a public board, so it is confined to /test/,
/// which exists for exactly this, and it posts once per run with a marker that
/// says where it came from.
@MainActor
final class PostingUITests: LiveUITestCase {
    func testTheReplyFormOpensAndLoadsACaptcha() throws {
        let app = launchApp()
        openTestBoard(app)

        app.buttons["New thread"].firstMatch.tap()

        // The captcha panel is the part that must work; everything else on the
        // form is local.
        XCTAssertTrue(
            app.staticTexts["Captcha"].waitForExistence(timeout: 30),
            "the reply form did not show a captcha panel"
        )
        XCTAssertTrue(
            app.staticTexts["Pick every symbol shown above. Order does not matter, and some appear only later."]
                .waitForExistence(timeout: 30)
                || app.staticTexts["No captcha needed"].exists,
            "the captcha never loaded a keyboard"
        )

        attach(app, name: "08-reply-form")
    }

    func testSendIsBlockedUntilTheCaptchaIsSolved() throws {
        let app = launchApp()
        openTestBoard(app)

        app.buttons["New thread"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Captcha"].waitForExistence(timeout: 30),
            "the reply form did not open"
        )

        // Typing alone must not enable sending: the captcha is unsolved.
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no comment field")
        editor.tap()
        editor.typeText("проверка")

        XCTAssertFalse(
            app.buttons["Send"].isEnabled,
            "sending should stay disabled until the captcha is solved"
        )
    }

    /// Markup has to go *around* what is picked.
    ///
    /// The toolbar could always wrap a selection, but the editor was bound to
    /// the text alone and never reported one, so every style landed after the
    /// comment instead of around the words it was meant for.
    func testAStyleWrapsTheSelectedText() throws {
        let app = launchApp()
        openTestBoard(app)

        app.buttons["New thread"].firstMatch.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "no comment field")
        // The form restores the board's draft, so whatever an earlier test left
        // behind is still in the field and would be what the tap lands on.
        clear(editor)
        editor.typeText("alpha")

        // A double tap on the word picks it, which is how a reader does this;
        // the edit menu is avoided because its wording follows the device.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).doubleTap()

        app.buttons["Bold"].firstMatch.tap()

        XCTAssertEqual(
            editor.value as? String,
            "**alpha**",
            "the markup did not wrap the selection"
        )

        attach(app, name: "09-markup-selection")
    }

    // MARK: Helpers

    /// Empties a text view, cursor first.
    private func clear(_ editor: XCUIElement) {
        editor.tap()
        // The end of the text, so the deletes come off the back of it.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        let existing = (editor.value as? String) ?? ""
        guard !existing.isEmpty else { return }
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        XCTAssertEqual(editor.value as? String, "", "the comment field did not clear")
    }

    private func openTestBoard(_ app: XCUIApplication) {
        // The board list's own field resolves a board code, which is how the
        // app reaches a board that is not in view.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: Self.networkTimeout),
            "the board list has no search field"
        )
        field.tap()
        field.typeText("test")

        let destination = app.staticTexts["/test/"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10), "the board was not resolved")
        destination.tap()

        XCTAssertTrue(
            app.buttons["New thread"].firstMatch.waitForExistence(timeout: 30),
            "the board did not load, or does not allow posting"
        )
    }

}
