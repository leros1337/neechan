import NeechanCore
import Observation
import SwiftUI

/// A screen pushed on top of a tab.
public enum AppRoute: Hashable, Sendable {
    case board(String)
    case thread(ThreadKey, scrollTo: Int?)
    /// A thread read from the copy on the device rather than from the site.
    case savedThread(ThreadKey)
    case archive(String)
    case serverSearch(String)
    /// The boards readers made themselves.
    case userBoards
    case statistics

    public static func thread(_ key: ThreadKey) -> AppRoute {
        .thread(key, scrollTo: nil)
    }
}

/// The navigation stack for each tab.
///
/// Held above the views so a tap on a `>>N` in a thread, a history row and the
/// search box can all push onto the same stack.
@MainActor
@Observable
public final class Router {
    public var selectedTab: AppTab = .boards
    public var boardsPath: [AppRoute] = []
    public var favoritesPath: [AppRoute] = []
    public var historyPath: [AppRoute] = []
    public var settingsPath: [AppRoute] = []

    /// Whether a window is on screen over the current screen, such as the
    /// favorites a thread can show without the reader leaving it.
    ///
    /// A window is a way of looking something up, not a place to be: what is
    /// chosen in one opens on the stack underneath, and the window goes.
    public private(set) var isWindowOpen = false

    public init() {}

    /// Starts on the board the reader asked to open on.
    ///
    /// Seeded here rather than pushed once the app is up, so the board list
    /// does not appear for a moment first. The board sits on top of the list
    /// rather than replacing it, so Back goes where it always goes.
    ///
    /// - Parameter defaultBoard: whatever is stored in settings, in whatever
    ///   shape the reader typed it. Anything that cannot be a board code opens
    ///   the board list, which is what the app did before there was a choice.
    public convenience init(defaultBoard: String?) {
        self.init()
        guard let code = defaultBoard.flatMap(BoardCode.normalized) else { return }
        boardsPath = [.board(code)]
    }

    /// The stack belonging to the tab currently on screen.
    public var activePath: [AppRoute] {
        get {
            switch selectedTab {
            case .boards: boardsPath
            case .favorites: favoritesPath
            case .history: historyPath
            case .settings: settingsPath
            }
        }
        set {
            switch selectedTab {
            case .boards: boardsPath = newValue
            case .favorites: favoritesPath = newValue
            case .history: historyPath = newValue
            case .settings: settingsPath = newValue
            }
        }
    }

    public func openWindow() {
        isWindowOpen = true
    }

    public func closeWindow() {
        isWindowOpen = false
    }

    /// Opens a screen on the stack the reader is in.
    ///
    /// A push from inside a window closes it on the way. Screens in this app
    /// never push themselves — they all call this — so a window can show the
    /// favorites list unchanged and still hand the reader over to the thread
    /// they chose, rather than showing it inside a card they then have to
    /// close.
    public func push(_ route: AppRoute) {
        guard isWindowOpen else {
            activePath.append(route)
            return
        }
        closeWindow()

        switch route {
        case .thread, .savedThread:
            // Kept on top of what the reader was reading, so Back returns to
            // the thread they opened the window from.
            activePath.append(route)
        default:
            // A board starts a fresh line of travel rather than landing on top
            // of a thread. A thread hides the tab bar for everything above it
            // as well as for itself, so a board opened there arrived with no
            // way back to the rest of the app.
            activePath = [route]
        }
    }

    /// Threads open on any tab's stack.
    ///
    /// What must survive a memory warning: a thread the reader can get back to
    /// with the back button should not have to be fetched again. Every tab is
    /// consulted, not just the one on screen, because the others keep their
    /// stacks while hidden.
    public var openThreadKeys: Set<ThreadKey> {
        let everyPath = [boardsPath, favoritesPath, historyPath, settingsPath].joined()
        return Set(
            everyPath.compactMap { route in
                switch route {
                case .thread(let key, _), .savedThread(let key): key
                default: nil
                }
            }
        )
    }

    /// Opens whatever the search box resolved to, in the tab that suits it.
    public func open(_ target: NavigationTarget) {
        switch target {
        case .board(let board):
            selectedTab = .boards
            boardsPath = [.board(board)]
        case .thread(let board, let threadNum):
            selectedTab = .boards
            boardsPath = [.board(board), .thread(ThreadKey(board: board, threadNum: threadNum))]
        case .threadAtPost(let board, let threadNum, let postNum):
            selectedTab = .boards
            boardsPath = [
                .board(board),
                .thread(ThreadKey(board: board, threadNum: threadNum), scrollTo: postNum),
            ]
        case .post(let board, let num):
            // The thread is unknown until the post is looked up; the search
            // screen resolves it before pushing.
            selectedTab = .boards
            boardsPath = [.board(board), .thread(ThreadKey(board: board, threadNum: num), scrollTo: num)]
        }
    }
}
