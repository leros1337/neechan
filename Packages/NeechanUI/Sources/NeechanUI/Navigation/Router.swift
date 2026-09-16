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

    public init() {}

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

    public func push(_ route: AppRoute) {
        activePath.append(route)
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
