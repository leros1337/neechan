import XCTest

/// Boot-level checks. These run against the real app on a simulator, so they
/// assert only what must be true the moment the shell appears.
@MainActor
final class LaunchSmokeUITests: LiveUITestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testLaunchShowsTheTabShell() {
        let app = launchApp()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 10),
            "the Liquid Glass tab bar should be on screen at launch"
        )
        for label in ["Favorites", "History", "Settings", "Boards"] {
            XCTAssertTrue(
                app.buttons[label].exists || app.tabBars.buttons[label].exists,
                "missing tab: \(label)"
            )
        }
    }

    func testBoardsIsTheLandingSection() {
        let app = launchApp()
        XCTAssertTrue(
            app.navigationBars["Boards"].waitForExistence(timeout: 10),
            "the app should land on Boards"
        )
    }

    func testThereIsNoSeparateSearchTab() {
        let app = launchApp()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 10)
        // Search folded into the board list, so the detached capsule is gone and
        // Boards sits at the thumb end of the bar instead.
        XCTAssertFalse(
            app.tabBars.buttons["Search"].exists,
            "the search tab should no longer exist"
        )
    }
}
