import XCTest

/// What a board row shows, and what hiding one does to it.
@MainActor
final class ThreadCardUITests: LiveUITestCase {
    /// The site fills `subject` with the start of the opening post when the
    /// poster left it empty, so the card used to draw the same words twice:
    /// once in bold as a title and again underneath as the preview.
    func testACardDoesNotRepeatTheOpeningPostAsItsTitle() throws {
        let app = launchApp()
        openDefaultBoard(app)

        let cells = app.cells.allElementsBoundByIndex.prefix(12)
        XCTAssertFalse(cells.isEmpty, "the board showed no threads")

        for cell in cells {
            let lines = cell.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 20 }
            guard lines.count >= 2 else { continue }

            let title = Self.comparable(lines[0])
            let preview = Self.comparable(lines[1])
            XCTAssertFalse(
                !title.isEmpty && preview.hasPrefix(title),
                "a card repeats its own text as a title: \(lines[0]) / \(lines[1])"
            )
        }

        // And no card falls back to a bold line holding only a post number.
        let numberOnly = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "\u{2116}[0-9]+"))
            .firstMatch
        XCTAssertFalse(numberOnly.exists, "a card still shows its number as a title")

        attach(app, name: "22-thread-cards")
    }

    /// Hiding is about not wanting to look at a thread, not about never seeing
    /// it again: the row collapses to a dim line that brings it back.
    func testHidingCollapsesTheRowRatherThanRemovingIt() throws {
        let app = launchApp()
        openDefaultBoard(app)

        let firstThread = replyCounts(app).firstMatch
        XCTAssertTrue(firstThread.waitForExistence(timeout: Self.networkTimeout))
        firstThread.press(forDuration: 1.0)

        let hide = app.buttons["Hide thread"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "a thread cannot be hidden")
        hide.tap()

        let stub = app.descendants(matching: .any)
            .matching(identifier: "hidden-thread")
            .firstMatch
        XCTAssertTrue(
            stub.waitForExistence(timeout: 10),
            "hiding removed the thread instead of collapsing it"
        )

        attach(app, name: "23-hidden-stub")

        // And it goes back, so the test leaves the board as it found it. By
        // label, because an earlier run may have left other threads hidden and
        // any of those would answer to the same identifier.
        let label = stub.label
        stub.tap()
        let sameStub = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "hidden-thread", label))
            .firstMatch
        XCTAssertTrue(
            waitForDisappearance(of: sameStub, timeout: 10),
            "the thread did not come back when the stub was tapped"
        )
    }

    /// Lower-cased, whitespace collapsed, and without the ellipsis the site
    /// truncates a made-up subject with.
    private static func comparable(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return String(collapsed.reversed().drop { $0 == "." || $0 == "\u{2026}" }.reversed())
    }
}
