import Foundation
import NeechanAPI
import NeechanCore
import Testing
@testable import NeechanUI

@Suite("Switching imageboards")
@MainActor
struct SiteSwitchTests {
    /// Nothing on any stack survives: every route on them names a board or a
    /// thread on the site the reader has just left, and the client can no
    /// longer fetch any of it.
    @Test("switching empties every tab's stack, not just the one on screen")
    func everyStackIsCleared() {
        let router = Router()
        router.boardsPath = [.board("b"), .thread(ThreadKey(site: .dvach, board: "b", threadNum: 1))]
        router.favoritesPath = [.thread(ThreadKey(site: .dvach, board: "b", threadNum: 2))]
        router.historyPath = [.thread(ThreadKey(site: .dvach, board: "po", threadNum: 3))]
        router.settingsPath = [.statistics]

        router.resetForSiteChange(defaultBoard: nil, site: .fourchan)

        #expect(router.boardsPath.isEmpty)
        #expect(router.favoritesPath.isEmpty)
        #expect(router.historyPath.isEmpty)
        #expect(router.settingsPath.isEmpty)
    }

    @Test("the new imageboard's own default board is opened, if there is one")
    func defaultBoardIsSeeded() {
        let router = Router()
        router.resetForSiteChange(defaultBoard: "g", site: .fourchan)
        #expect(router.boardsPath == [.board("g")])
    }

    /// Typing `3` on a site with no numeric board is a post number, not a
    /// board, so seeding has to ask the site it is seeding for.
    @Test("a default board the new imageboard cannot have is ignored")
    func impossibleDefaultBoardIsDropped() {
        let router = Router()
        router.resetForSiteChange(defaultBoard: "3", site: .dvach)
        #expect(router.boardsPath.isEmpty)

        router.resetForSiteChange(defaultBoard: "3", site: .fourchan)
        #expect(router.boardsPath == [.board("3")])
    }

    /// The reader switched from somewhere; moving them to another tab as well
    /// would be a second surprise.
    @Test("the tab the reader is on is left alone")
    func selectedTabIsUntouched() {
        let router = Router()
        router.selectedTab = .favorites
        router.resetForSiteChange(defaultBoard: nil, site: .fourchan)
        #expect(router.selectedTab == .favorites)
    }

    @Test("a window open over a thread is closed on the way")
    func windowIsClosed() {
        let router = Router()
        router.openWindow()
        #expect(router.isWindowOpen)

        router.resetForSiteChange(defaultBoard: nil, site: .fourchan)
        #expect(router.isWindowOpen == false)
    }
}
