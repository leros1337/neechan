import NeechanCore
import Testing
@testable import NeechanUI

/// Where a push lands, now that a window can be open over a tab.
/// Where the app starts.
@MainActor
@Suite("Router start")
struct RouterStartTests {
    @Test("the board the reader asked for opens, with the board list behind it")
    func opensTheDefaultBoard() {
        let router = Router(defaultBoard: "b")

        #expect(router.selectedTab == .boards)
        #expect(router.boardsPath == [.board("b")])
    }

    /// However the reader wrote it in settings.
    @Test(
        "the code is read the way it is everywhere else",
        arguments: ["b", "/b/", " B "]
    )
    func normalisesTheCode(stored: String) {
        #expect(Router(defaultBoard: stored).boardsPath == [.board("b")])
    }

    @Test(
        "nothing to open leaves the board list",
        arguments: [nil, "", "   ", "hello world", "12345"]
    )
    func staysOnTheList(stored: String?) {
        #expect(Router(defaultBoard: stored).boardsPath.isEmpty)
    }

    /// The other tabs are not where a default board belongs.
    @Test("only the boards tab is seeded")
    func onlyTheBoardsTab() {
        let router = Router(defaultBoard: "b")

        #expect(router.favoritesPath.isEmpty)
        #expect(router.historyPath.isEmpty)
        #expect(router.settingsPath.isEmpty)
    }
}

@MainActor
@Suite("Router windows")
struct RouterWindowTests {
    private func key(_ num: Int) -> ThreadKey {
        ThreadKey(board: "b", threadNum: num)
    }

    @Test("with no window open, a push lands on the tab the reader is in")
    func pushGoesToTheTab() {
        let router = Router()
        router.selectedTab = .boards

        router.push(.thread(key(1)))

        #expect(router.boardsPath.count == 1)
    }

    /// A window is for looking something up, not for reading in. What is
    /// chosen there opens where the reader already was, on top of the screen
    /// the window was covering, so Back goes back to it.
    @Test("choosing something in a window opens it on the tab, not in the window")
    func pushFromAWindowLandsOnTheTab() {
        let router = Router()
        router.selectedTab = .boards
        router.push(.board("b"))
        router.openWindow()

        router.push(.thread(key(1)))

        #expect(router.boardsPath == [.board("b"), .thread(key(1))])
    }

    /// A thread hides the tab bar for everything above it as well as for
    /// itself, so a board pushed on top of one arrives with no way back to the
    /// rest of the app. It starts a line of travel of its own instead.
    @Test("a board chosen in a window replaces what was open rather than sitting on it")
    func boardsFromAWindowStartFresh() {
        let router = Router()
        router.selectedTab = .boards
        router.push(.board("b"))
        router.push(.thread(key(1)))
        router.openWindow()

        router.push(.board("vg"))

        #expect(router.boardsPath == [.board("vg")])
    }

    @Test("choosing something closes the window that offered it")
    func pushClosesTheWindow() {
        let router = Router()
        router.openWindow()

        router.push(.thread(key(1)))

        #expect(router.isWindowOpen == false)
    }

    @Test("a window can be closed without choosing anything")
    func closingChangesNothingElse() {
        let router = Router()
        router.selectedTab = .boards
        router.push(.board("b"))
        router.openWindow()

        router.closeWindow()

        #expect(router.isWindowOpen == false)
        #expect(router.boardsPath == [.board("b")])
    }
}
