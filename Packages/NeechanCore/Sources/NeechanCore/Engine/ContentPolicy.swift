import Foundation
import NeechanAPI
import Synchronization

/// What the reader has said they are willing to be shown.
///
/// A value rather than a reach back into settings, so the repositories that
/// enforce it stay testable and so an actor never has to hop to the main actor
/// to ask a question about a board.
///
/// Posting is deliberately not here. Nothing crosses an isolation boundary for
/// it: it is read by three toolbar gates and one send guard, all on the main
/// actor, and modelling it here would suggest otherwise.
public struct ContentPolicy: Sendable, Hashable {
    /// Whether boards meant for adults may be opened. The reader's own switch.
    ///
    /// It no longer decides what the *directory* lists — see ``lists(code:on:)``.
    /// Nothing is hidden from the board list any more; the gate is asked at the
    /// moment a board is opened, where it can say so and offer the way through.
    public var allowsMatureBoards: Bool

    /// Whether the board directory lists every board the site has.
    ///
    /// False only in the App Store build, whose directory carries anime, manga
    /// and comics and nothing else. Independent of ``allowsMatureBoards``: that
    /// switch unlocks *reaching* a board, not what the list shows.
    public var listsEveryBoard: Bool

    public init(allowsMatureBoards: Bool = true, listsEveryBoard: Bool = true) {
        self.allowsMatureBoards = allowsMatureBoards
        self.listsEveryBoard = listsEveryBoard
    }

    /// Everything allowed, which is what a caller with no reader behind it wants.
    public static let unrestricted = ContentPolicy()

    /// Whether the reader's own lists may carry this board.
    ///
    /// The adult gate and nothing else. Favorites, History, Saved threads and
    /// the watcher ask this, so the App Store build's narrower directory does
    /// not retro-hide something the reader saved.
    public func allows(code: String, on site: Imageboard) -> Bool {
        allowsMatureBoards || !MatureBoards.contains(code, on: site)
    }

    /// Whether the board directory lists this board.
    ///
    /// Deliberately free of ``allowsMatureBoards``: an adult board is listed
    /// and then refused on the way in, rather than vanishing with no
    /// explanation of where it went.
    public func lists(code: String, on site: Imageboard) -> Bool {
        listsEveryBoard || AppStoreBoards.contains(code, on: site)
    }

    public func lists(_ board: Board, on site: Imageboard) -> Bool {
        listsEveryBoard || AppStoreBoards.contains(board, on: site)
    }

    /// Whether this board can be opened at all.
    ///
    /// Two ways to be refused, one way through. A board for adults is refused,
    /// and so is a board the directory does not list — which in the App Store
    /// build is everything outside anime, manga and comics. The adult switch
    /// lifts both, because it is the reader saying how old they are, and that
    /// is the only thing either refusal is really protecting.
    public func allowsOpening(code: String, on site: Imageboard) -> Bool {
        allowsMatureBoards || (allows(code: code, on: site) && lists(code: code, on: site))
    }

    public func allowsOpening(_ ref: BoardRef) -> Bool {
        allowsOpening(code: ref.code, on: ref.site)
    }

    public func allowsOpening(_ key: ThreadKey) -> Bool {
        allowsOpening(code: key.board, on: key.site)
    }

    /// Whether whatever the go-to field resolved to may be opened.
    ///
    /// A pasted link resolves to the site its own host names, so the target
    /// carries the site to judge it on.
    public func allowsOpening(_ target: NavigationTarget) -> Bool {
        switch target {
        case .board(let board): allowsOpening(board)
        case .thread(let key), .threadAtPost(let key, _): allowsOpening(key)
        case .post(let board, _): allowsOpening(board)
        }
    }

    public func allows(_ board: Board, on site: Imageboard) -> Bool {
        allowsMatureBoards || !MatureBoards.contains(board, on: site)
    }

    /// Judged on the board's own imageboard, never the selected one.
    ///
    /// The codes genuinely collide: `/t/` is Torrents on 4chan and Техника on
    /// 2ch, `/d/` is Hentai/Alternative on one and Склад грязи on the other. A
    /// board has to be measured against its own site's table or a reader with
    /// 2ch open gets the wrong answer about a 4chan link they just pasted.
    public func allows(_ ref: BoardRef) -> Bool {
        allows(code: ref.code, on: ref.site)
    }

    public func allows(_ key: ThreadKey) -> Bool {
        allows(code: key.board, on: key.site)
    }

    /// The codes to exclude, for a query that must do its own filtering.
    ///
    /// A `#Predicate` cannot call into this type, and a fetch that applies a
    /// limit has to exclude the restricted rows *before* the limit or a reader
    /// whose most recent hundred threads are all restricted would be shown an
    /// empty list with allowed threads sitting just below it. Empty when
    /// nothing is restricted, which makes the predicate a no-op.
    public func blockedCodes(on site: Imageboard) -> [String] {
        allowsMatureBoards ? [] : Array(MatureBoards.effectiveCodes(on: site))
    }

    /// The directory, narrowed to what this build lists.
    public func filter(_ boards: [Board], on site: Imageboard) -> [Board] {
        guard !listsEveryBoard else { return boards }
        return boards.filter { AppStoreBoards.contains($0, on: site) }
    }
}

/// Supplies the current policy to long-lived collaborators, so a change in
/// settings takes effect without rebuilding them.
///
/// The same shape as `SiteProvider`, and for the same reason: the repositories
/// read it from their own actor's executor, so it must be callable from any
/// isolation. Use `ContentPolicyHolder` rather than closing over main-actor
/// state.
public typealias ContentPolicyProvider = @Sendable () -> ContentPolicy

/// A mutable policy that can be read from any isolation.
public final class ContentPolicyHolder: Sendable {
    private let storage: Mutex<ContentPolicy>

    public init(_ initial: ContentPolicy = .unrestricted) {
        storage = Mutex(initial)
    }

    public var value: ContentPolicy {
        storage.withLock { $0 }
    }

    public func set(_ policy: ContentPolicy) {
        storage.withLock { $0 = policy }
    }

    /// A provider bound to this holder. Captures the holder and nothing else,
    /// so it cannot keep the services that built it alive.
    public var provider: ContentPolicyProvider {
        { [self] in value }
    }
}

/// A policy provider that can be installed after its actor has been built.
///
/// `@ModelActor` synthesizes the only designated initialiser those actors have,
/// and it is nonisolated, so a delegating initialiser cannot assign an isolated
/// stored property. This can be written from there because it is `Sendable` and
/// carries its own lock. Actors that write their own initialiser — like
/// `BoardsRepository` — take the provider directly and have no need of this.
public final class ContentPolicyPort: Sendable {
    private let storage: Mutex<ContentPolicyProvider>

    public init(_ provider: @escaping ContentPolicyProvider = { .unrestricted }) {
        storage = Mutex(provider)
    }

    public func use(_ provider: @escaping ContentPolicyProvider) {
        storage.withLock { $0 = provider }
    }

    /// The policy right now. The provider is copied out before it is called, so
    /// nothing runs while the lock is held.
    public var policy: ContentPolicy {
        let provider = storage.withLock { $0 }
        return provider()
    }
}
