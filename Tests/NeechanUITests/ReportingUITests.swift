import XCTest

/// The report action, from the menu to the form.
///
/// **Nothing here sends a report.** Every test stops before submitting and
/// checks only that the way in works. A test that submitted would file real
/// complaints with real moderators on every run, which is an abuse of them; 2ch
/// also answers a repeat with `-52`, so the second run would be testing the
/// error path by accident.
@MainActor
final class ReportingUITests: LiveUITestCase {
    /// The comment field, whichever element kind SwiftUI made of it.
    ///
    /// A `TextField` on a vertical axis is reported as a text view on some iOS
    /// versions and as a text field on others, and which one it is says nothing
    /// about whether the form works.
    private func commentField(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "report-comment").firstMatch
    }

    /// Opens a board, its first thread, and the first post's menu.
    private func openPostMenu(_ app: XCUIApplication, board: String) {
        let row = app.staticTexts[board]
        XCTAssertTrue(
            row.waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )
        row.tap()
        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "\(board) did not load its threads"
        )
        useCardsLayout(app)
        openFirstThread(app)
        anyPostNumber(app).press(forDuration: 1.0)
    }

    func testAPostOffersReporting() throws {
        let app = launchApp()
        openPostMenu(app, board: "/b/")

        XCTAssertTrue(
            app.buttons["Report"].firstMatch.waitForExistence(timeout: 10),
            "the post menu offers no way to report the post"
        )
        attach(app, name: "report-menu")
    }

    /// An empty complaint is refused here rather than by the site, which answers
    /// one with `-51 ErrorReportEmpty` after a round trip.
    func testSendIsBlockedUntilSomethingIsWritten() throws {
        let app = launchApp()
        openPostMenu(app, board: "/b/")

        let report = app.buttons["Report"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10), "no Report in the post menu")
        report.tap()

        let comment = commentField(app)
        XCTAssertTrue(comment.waitForExistence(timeout: 10), "the report form did not open")

        let send = app.buttons["report-send"].firstMatch
        XCTAssertTrue(send.exists, "the report form has no Send button")
        XCTAssertFalse(send.isEnabled, "an empty report could be sent")

        comment.tap()
        comment.typeText("test")
        XCTAssertTrue(send.isEnabled, "a written report could not be sent")

        attach(app, name: "report-form")

        // Send is deliberately not tapped. See the note on this class.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            waitForDisappearance(of: comment, timeout: 10),
            "cancelling left the report form up"
        )
    }

    /// 4chan is reported through its own page rather than through an API, so the
    /// branch the sheet takes is a different one and worth its own run.
    ///
    /// `/3/` rather than the `/b/` the other tests use: this one waits on the
    /// page's own wording, and a board that turns over every few seconds is a
    /// worse place to hold a thread open. It is also near the top of 4chan's
    /// board list, which is lazily built -- a code further down is not in the
    /// hierarchy to be tapped at all.
    func testFourchanOpensTheSitesOwnReportPage() throws {
        let app = launchApp(pinsImageboard: false)
        switchToImageboard("4chan", in: app)
        openPostMenu(app, board: "/3/")

        let report = app.buttons["Report"].firstMatch
        XCTAssertTrue(
            report.waitForExistence(timeout: 10),
            "a 4chan post offers no way to report it"
        )
        report.tap()

        // A web view, and no comment field: together they say this took the
        // page route rather than drawing the form the app uses for 2ch.
        //
        // Asserted on the branch rather than on the page's own wording --
        // "Report type" is an HTML `legend`, which does not come back as a
        // static text, and pinning a test to a third party's markup would
        // break the day they reword it.
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "4chan's report page did not open"
        )
        XCTAssertFalse(
            commentField(app).exists,
            "4chan was given the 2ch report form"
        )
        attach(app, name: "report-fourchan")

        app.buttons["Close"].firstMatch.tap()
    }
}
