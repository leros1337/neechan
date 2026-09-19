import XCTest

/// Hiding a post from inside a thread.
///
/// The reply index and the strikethrough on a `>>N` are driven by the same set
/// the thread's own rows read, so this is the test that says whether the post
/// itself actually goes.
@MainActor
final class HiddenPostsUITests: LiveUITestCase {
    /// A thread with plenty of posts and plenty of quoting between them.
    private static let thread = "https://2ch.org/mobi/res/2760513.html"

    func testHidingAPostReplacesItWithAStub() {
        let app = launchApp()

        // The board filter doubles as the go-to field, which takes a full link.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: Self.networkTimeout), "no board list")
        field.tap()
        field.typeText(Self.thread)

        let go = app.buttons["go-to"].firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 10), "the link was not offered")
        go.tap()

        // An ordinary post, not the opening one, which is a special case.
        let bodies = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'post-body-'"))
        XCTAssertTrue(
            bodies.element(boundBy: 1).waitForExistence(timeout: Self.networkTimeout),
            "the thread did not load"
        )
        let target = bodies.element(boundBy: 1)
        let hiddenNum = target.identifier.replacingOccurrences(of: "post-body-", with: "")

        target.press(forDuration: 1.0)

        let hideMenu = app.buttons["Hide"].firstMatch
        XCTAssertTrue(hideMenu.waitForExistence(timeout: 10), "no Hide item in the context menu")
        hideMenu.tap()

        let thisPost = app.buttons["This post"].firstMatch
        XCTAssertTrue(thisPost.waitForExistence(timeout: 10), "no 'This post' item under Hide")
        thisPost.tap()

        attach(app, name: "after-hiding-a-post")

        XCTAssertTrue(
            app.staticTexts["Hidden post"].firstMatch.waitForExistence(timeout: 10),
            "post №\(hiddenNum) was not replaced by a stub"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["post-body-\(hiddenNum)"].exists,
            "post №\(hiddenNum) is still drawn in full"
        )

        clearHiddenPosts(app)
    }

    /// Best effort, and deliberately not assertive.
    ///
    /// A hide rule is a row in the store rather than a preference, so no launch
    /// argument resets it: a run that left one behind hides a different post
    /// next time, and enough runs would work through the thread. Removing one
    /// means swiping a row, which is the flakiest gesture here and has nothing
    /// to do with what this test is about -- so a cleanup that does not take
    /// leaves the next run to hide the next post down, which it handles, and
    /// does not fail a test that has already proved its point.
    private func clearHiddenPosts(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 2).tap()

        let entry = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH 'hidden posts'")
        ).firstMatch
        guard entry.waitForExistence(timeout: 10) else { return }
        entry.tap()

        let rules = app.collectionViews.cells
        guard rules.element(boundBy: 0).waitForExistence(timeout: 10) else { return }
        while rules.count > 0 {
            rules.element(boundBy: 0).swipeLeft()
            let remove = app.buttons["Remove"].firstMatch
            guard remove.waitForExistence(timeout: 5) else { break }
            remove.tap()
        }

        app.buttons["Done"].firstMatch.tap()
    }
}
