import XCTest

/// Every board layout must lay out inside the screen.
///
/// The grids used to ask their thumbnails to fill a square, which grows a view
/// past the space it was offered, so cells overlapped their neighbours.
@MainActor
final class BoardLayoutUITests: LiveUITestCase {
    func testEveryLayoutFitsTheScreen() throws {
        let app = launchApp()
        openDefaultBoard(app)

        for layout in ["List", "Cards", "Grid"] {
            selectLayout(layout, in: app)
            assertCellsFitTheScreen(app, layout: layout)
            attach(app, name: "14-layout-\(layout.replacingOccurrences(of: " ", with: "-"))")
        }
    }

    // MARK: Helpers

    private func selectLayout(_ name: String, in app: XCUIApplication) {
        let options = app.buttons["View options"].firstMatch
        XCTAssertTrue(
            options.waitForExistence(timeout: Self.networkTimeout),
            "the board has no view options"
        )
        options.tap()

        let choice = app.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the menu has no '\(name)' layout")
        choice.tap()

        XCTAssertTrue(
            replyCounts(app).firstMatch.waitForExistence(timeout: Self.networkTimeout),
            "the board did not render in the '\(name)' layout"
        )
    }

    /// No cell may extend past the window, which is what overlapping looks like
    /// from the outside.
    private func assertCellsFitTheScreen(_ app: XCUIApplication, layout: String) {
        let screen = app.windows.firstMatch.frame
        let counts = replyCounts(app)

        for index in 0..<min(counts.count, 8) {
            let element = counts.element(boundBy: index)
            guard element.exists else { continue }
            let frame = element.frame
            guard frame.width > 0 else { continue }

            XCTAssertLessThanOrEqual(
                frame.maxX, screen.maxX + 1,
                "a cell runs off the right edge in the '\(layout)' layout"
            )
            XCTAssertGreaterThanOrEqual(
                frame.minX, screen.minX - 1,
                "a cell runs off the left edge in the '\(layout)' layout"
            )
        }
    }
}
