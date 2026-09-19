import NeechanAPI
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
    /// The screen holding the age gate. A route rather than a plain
    /// `NavigationLink` because a board refused anywhere in the app sends the
    /// reader here, and that has to land on the same screen Settings does.
    case restrictions

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

    /// What the reader is willing to be shown, and the imageboard they are on.
    ///
    /// Held here rather than reached for through `AppServices` so this stays a
    /// plain value type its tests can drive directly. The shell keeps both in
    /// step; nothing else writes them.
    public var policy: ContentPolicy = .unrestricted
    public var site: Imageboard = .default

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
    public convenience init(
        defaultBoard: String?,
        site: Imageboard = .default,
        policy: ContentPolicy = .unrestricted
    ) {
        self.init()
        self.site = site
        self.policy = policy
        guard let code = defaultBoard.flatMap({ BoardCode.normalized($0, for: site) }) else {
            return
        }
        // A restricted board can be sitting in settings from before the reader
        // closed the gate, and this is the one push that happens before any
        // screen exists to refuse it.
        guard policy.allowsOpening(code: code, on: site) else { return }
        boardsPath = [.board(code)]
    }

    /// Empties every stack after the imageboard changes.
    ///
    /// A route on any of them names a board or a thread on the site the reader
    /// has just left, and the client can no longer fetch it. `selectedTab` is
    /// deliberately left alone: the reader switched from somewhere, and moving
    /// them to another tab as well would be a second surprise.
    public func resetForSiteChange(defaultBoard: String?, site: Imageboard) {
        closeWindow()
        self.site = site
        if let code = defaultBoard.flatMap({ BoardCode.normalized($0, for: site) }),
            policy.allowsOpening(code: code, on: site) {
            boardsPath = [.board(code)]
        } else {
            boardsPath = []
        }
        favoritesPath = []
        historyPath = []
        settingsPath = []
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
        guard allows(route) else { return }
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
        guard policy.allowsOpening(target) else { return }
        selectedTab = .boards
        switch target {
        case .board(let board):
            boardsPath = [.board(board.code)]
        case .thread(let key):
            boardsPath = [.board(key.board), .thread(key)]
        case .threadAtPost(let key, let postNum):
            boardsPath = [.board(key.board), .thread(key, scrollTo: postNum)]
        case .post(let board, let num):
            // The thread is unknown until the post is looked up; the search
            // screen resolves it before pushing.
            let key = ThreadKey(site: board.site, board: board.code, threadNum: num)
            boardsPath = [.board(board.code), .thread(key, scrollTo: num)]
        }
    }

    // MARK: Restrictions

    /// Whether the reader's restrictions let this screen be opened.
    ///
    /// A thread is judged on *its own* imageboard rather than the selected one:
    /// a route can outlive a switch, and a pasted link resolves to whichever
    /// site its host names.
    public func allows(_ route: AppRoute) -> Bool {
        switch route {
        case .board(let code), .archive(let code), .serverSearch(let code):
            policy.allowsOpening(code: code, on: site)
        case .thread(let key, _), .savedThread(let key):
            policy.allowsOpening(key)
        case .userBoards:
            // Every board a 2ch reader made is restricted, so the screen behind
            // this has nothing on it to show.
            policy.allowsMatureBoards
        case .statistics, .restrictions:
            // Where the reader goes to lift a restriction. Refusing it would
            // shut the only door out.
            true
        }
    }

    /// Opens the screen carrying the age gate, from wherever the reader was
    /// refused. The stack is replaced rather than pushed onto, so Back leads
    /// out of Settings instead of deeper into the tab they came from.
    public func openRestrictions() {
        closeWindow()
        selectedTab = .settings
        settingsPath = [.restrictions]
    }

    /// Walks the reader out of anything they may no longer see.
    ///
    /// Called when a restriction is turned on, because a reader can be standing
    /// inside a board at the moment it becomes restricted. Each stack is cut at
    /// the first route that is now refused, since everything above it was
    /// reached through it.
    ///
    /// Turning the restriction back off does not put the stacks back, and
    /// should not: the reader has been returned to somewhere real, and
    /// resurrecting a screen they were walked out of minutes ago would be a
    /// surprise.
    public func pruneBlocked() {
        closeWindow()
        for path in [\Router.boardsPath, \.favoritesPath, \.historyPath, \.settingsPath] {
            if let cut = self[keyPath: path].firstIndex(where: { !allows($0) }) {
                self[keyPath: path].removeSubrange(cut...)
            }
        }
    }
}
