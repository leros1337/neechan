import NeechanAPI
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
        ThreadKey(site: .dvach, board: "b", threadNum: num)
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

/// Refusing a way into a board the reader has turned off.
///
/// `Router` is a plain value holder, so all of this can be asked of it directly
/// without a shell, a services object or a network.
@MainActor
@Suite("Router restrictions")
struct RouterRestrictionTests {
    private let blocked = ContentPolicy(allowsMatureBoards: false)

    private func router(site: Imageboard = .dvach) -> Router {
        let router = Router()
        router.site = site
        router.policy = blocked
        return router
    }

    @Test("the board the app opens on is refused if it is restricted")
    func aRestrictedDefaultBoardIsNotSeeded() {
        let seeded = Router(defaultBoard: "hc", site: .dvach, policy: blocked)
        #expect(seeded.boardsPath.isEmpty, "the app opened straight onto a restricted board")

        let allowed = Router(defaultBoard: "a", site: .dvach, policy: blocked)
        #expect(allowed.boardsPath == [.board("a")])
    }

    @Test("a restricted board is not seeded after an imageboard switch either")
    func aRestrictedDefaultBoardIsNotSeededOnSwitch() {
        let router = router()
        router.resetForSiteChange(defaultBoard: "b", site: .fourchan)
        #expect(router.boardsPath.isEmpty)

        router.resetForSiteChange(defaultBoard: "a", site: .fourchan)
        #expect(router.boardsPath == [.board("a")])
    }

    @Test(
        "every shape of route into a restricted board is refused",
        arguments: [
            AppRoute.board("hc"),
            AppRoute.archive("hc"),
            AppRoute.serverSearch("hc"),
            AppRoute.thread(ThreadKey(site: .dvach, board: "hc", threadNum: 1)),
            AppRoute.savedThread(ThreadKey(site: .dvach, board: "hc", threadNum: 1)),
            // Every board a 2ch reader made is restricted, so the screen
            // listing them has nothing left to show.
            AppRoute.userBoards,
        ]
    )
    func restrictedRoutesAreRefused(route: AppRoute) {
        let router = router()
        #expect(!router.allows(route))
        router.push(route)
        #expect(router.boardsPath.isEmpty, "\(route) was pushed anyway")
    }

    /// The screen holding the age gate is the way out of every refusal above,
    /// so refusing it too would shut the only door.
    @Test("the restrictions screen is never refused")
    func theRestrictionsScreenIsAlwaysReachable() {
        let router = router()
        #expect(router.allows(.restrictions))

        router.push(.restrictions)
        #expect(router.boardsPath == [.restrictions])
    }

    /// Where a reader lands after being refused a board, from anywhere.
    @Test("opening the restrictions screen switches tab and replaces the stack")
    func openRestrictionsLandsInSettings() {
        let router = router()
        router.settingsPath = [.statistics]

        router.openRestrictions()

        #expect(router.selectedTab == .settings)
        #expect(router.settingsPath == [.restrictions], "Back would lead deeper into Settings")
    }

    /// The App Store build's narrower directory is a second, independent reason
    /// to refuse — and the age gate lifts it, which is what lets a reader reach
    /// a board by typing its code.
    @Test("a board the directory does not list is refused until the gate is open")
    func anUnlistedBoardIsRefused() {
        let router = Router()
        router.site = .dvach
        router.policy = ContentPolicy(allowsMatureBoards: false, listsEveryBoard: false)

        #expect(!router.allows(.board("vg")), "an unlisted board was reachable")
        #expect(router.allows(.board("a")))

        router.policy = ContentPolicy(allowsMatureBoards: true, listsEveryBoard: false)
        #expect(router.allows(.board("vg")), "the age gate did not unlock it")
    }

    @Test("an ordinary board is still reachable")
    func allowedRoutesStillPush() {
        let router = router()
        router.push(.board("a"))
        router.push(.thread(ThreadKey(site: .dvach, board: "a", threadNum: 7)))
        #expect(router.boardsPath.count == 2)
        #expect(router.allows(.statistics))
    }

    /// A route can outlive a switch, and a pasted link resolves to whichever
    /// site named it — so a thread is judged on its own.
    @Test("a thread is judged on its own imageboard, not the selected one")
    func threadsAreJudgedOnTheirOwnSite() {
        let onDvach = router(site: .dvach)
        // /s/ is Программы on 2ch and Sexy Beautiful Women on 4chan.
        #expect(onDvach.allows(.thread(ThreadKey(site: .dvach, board: "s", threadNum: 1))))
        #expect(!onDvach.allows(.thread(ThreadKey(site: .fourchan, board: "s", threadNum: 1))))
    }

    @Test("the go-to field cannot reach a restricted board either")
    func openIsRefused() {
        let router = router()
        router.open(NavigationTarget.board(BoardRef(site: .dvach, code: "hc")))
        #expect(router.boardsPath.isEmpty)

        router.open(NavigationTarget.thread(ThreadKey(site: .fourchan, board: "b", threadNum: 3)))
        #expect(router.boardsPath.isEmpty)

        router.open(NavigationTarget.board(BoardRef(site: .dvach, code: "a")))
        #expect(router.boardsPath == [.board("a")])
    }

    /// A reader can be standing inside a board at the moment it is restricted.
    @Test("pruning walks the reader out, keeping what is below the first refusal")
    func pruningCutsAtTheFirstBlockedRoute() {
        let router = Router()
        router.site = .dvach
        router.boardsPath = [
            .board("a"),
            .thread(ThreadKey(site: .dvach, board: "a", threadNum: 1)),
            .board("hc"),
            .thread(ThreadKey(site: .dvach, board: "hc", threadNum: 2)),
        ]
        router.historyPath = [.board("vg")]

        router.policy = blocked
        router.pruneBlocked()

        #expect(router.boardsPath.count == 2, "the reader was left inside a restricted board")
        #expect(router.historyPath == [.board("vg")], "an allowed stack was disturbed")
    }

    /// Deliberate: the reader has been put somewhere real, and resurrecting a
    /// screen they were walked out of would be its own surprise.
    @Test("opening the gate again does not put back what was pruned")
    func pruningIsNotUndone() {
        let router = Router()
        router.site = .dvach
        router.boardsPath = [.board("hc")]
        router.policy = blocked
        router.pruneBlocked()
        #expect(router.boardsPath.isEmpty)

        router.policy = .unrestricted
        #expect(router.boardsPath.isEmpty)
    }
}
