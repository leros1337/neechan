import XCTest

/// The board directory, which used to list the reader-made boards twice: once
/// as their own row and again as a category of dozens in the middle of the list.
@MainActor
final class BoardDirectoryUITests: LiveUITestCase {
    /// The site's own name for the category; it is server data, not app copy.
    private let userBoardCategory = "Пользовательские"

    func testUserBoardsAreNotACategoryInTheDirectory() throws {
        let app = launchApp()
        XCTAssertTrue(
            app.staticTexts["/b/"].waitForExistence(timeout: Self.networkTimeout),
            "the board list did not load"
        )

        XCTAssertTrue(
            app.buttons["User boards"].firstMatch.exists,
            "the row that replaces the category is missing"
        )
        XCTAssertFalse(
            app.staticTexts[userBoardCategory].exists,
            "the directory still lists the user boards as a category"
        )

        // A category that does belong there is still shown, so the filter is
        // not simply hiding everything.
        XCTAssertTrue(app.staticTexts["Разное"].exists, "the other categories went too")
    }

    /// Hidden from browsing, still reachable by typing.
    func testAUserBoardIsStillFoundBySearch() throws {
        let code = try XCTUnwrap(
            UserBoardLookup.anyCode(), "the site lists no user boards right now"
        )
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["/b/"].waitForExistence(timeout: Self.networkTimeout))

        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 10) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the board filter is missing")
        field.tap()
        field.typeText(code)

        XCTAssertTrue(
            app.staticTexts["/\(code)/"].waitForExistence(timeout: 10),
            "a user board could not be found by typing its code"
        )
    }
}

/// Finds a board the site files under its user-made category.
enum UserBoardLookup {
    /// - Returns: nil rather than hanging when the site is slow. `Data(contentsOf:)`
    ///   has no useful timeout, and a test that waits forever reads as a stuck run.
    static func anyCode() -> String? {
        guard let url = URL(string: "https://2ch.org/api/mobile/v2/boards") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        var boards: [[String: Any]]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data else { return }
            boards = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        }
        .resume()
        _ = done.wait(timeout: .now() + 25)

        return boards?
            .first { $0["category"] as? String == "Пользовательские" }?["id"] as? String
    }
}
