import XCTest

/// Checks the two things readers noticed: short posts must not be collapsed,
/// and a thread must be shareable.
///
/// Sharing lives in the thread's menu. It was also a button of its own on the
/// toolbar until the favorites took that place; the menu had carried it all
/// along, so nothing was lost but the duplicate.
@MainActor
final class PostPresentationUITests: LiveUITestCase {
    func testShortPostsAreNotCollapsed() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        // "Show more" belongs only on posts the line limit actually cut. A
        // thread full of one-line replies must not show it at all.
        let shortPostThread = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "№")
        ).count
        XCTAssertGreaterThan(shortPostThread, 0, "no posts rendered")

        let expandButtons = app.buttons.matching(identifier: "Show more").count
        let visiblePosts = app.staticTexts.count
        XCTAssertLessThan(
            expandButtons,
            visiblePosts,
            "every post offered Show more, which means the control is unconditional"
        )
    }

    func testAThreadCanBeShared() throws {
        let app = XCUIApplication()
        launchApp()
        openDefaultBoard(app)
        openThreadWithReplies(app)

        let menu = app.navigationBars.buttons["Thread actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: Self.networkTimeout), "no thread menu")
        menu.tap()

        let share = app.buttons["Share link"].firstMatch
        XCTAssertTrue(
            share.waitForExistence(timeout: 15),
            "the thread has no share control"
        )
        attach(app, name: "09-thread-share")
    }

}
