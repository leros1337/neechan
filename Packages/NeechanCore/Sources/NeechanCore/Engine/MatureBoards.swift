import Foundation
import Synchronization
import NeechanAPI

/// The boards each imageboard keeps for adults.
///
/// A static table, because that is what the data is. It exists because the two
/// sites answer the question very differently:
///
/// - **4chan** says so itself. `ws_board` is decoded into ``Board/isWorkSafe``,
///   and the 24 boards below are exactly today's not-worksafe set.
/// - **2ch** says nothing at all: its decoder hardcodes `isWorkSafe = true` for
///   every board, because the API carries no such field. So on 2ch the table is
///   the only answer there is.
///
/// Most callers hold a board *code* and nothing else — a `ThreadKey` carries a
/// `String` — so ``contains(_:on:)-(String,_)`` is the authoritative form and the
/// `Board` form only adds the site's own flag on top of it.
public enum MatureBoards {
    /// Whether this code names a board meant for adults.
    ///
    /// Tolerant of how the code was written: a reader's `/HC/` and a stored
    /// `hc` are the same board, and `ThreadKey.board` never passed through
    /// ``BoardCode/normalized(_:for:)``.
    public static func contains(_ code: String, on site: Imageboard) -> Bool {
        let cleaned = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !cleaned.isEmpty else { return false }
        if codes(on: site).contains(cleaned) { return true }
        return learned.contains(site: site, code: cleaned)
    }

    /// The table, plus the site's own answer for a board it has not heard of.
    ///
    /// No branch on the site is needed: 2ch reports every board as worksafe, so
    /// the second half is a no-op there today and starts working on its own if
    /// that ever stops being true.
    public static func contains(_ board: Board, on site: Imageboard) -> Bool {
        contains(board.id, on: site) || !board.isWorkSafe
    }

    /// Everything restricted on this site right now: the table below plus any
    /// user-made board a directory has since named. For a caller that needs the
    /// whole list at once rather than one answer at a time — a database query
    /// that has to do its own filtering, for instance.
    public static func effectiveCodes(on site: Imageboard) -> Set<String> {
        codes(on: site).union(learned.codes(for: site))
    }

    public static func codes(on site: Imageboard) -> Set<String> {
        switch site {
        case .dvach: dvach
        case .fourchan: fourchan
        }
    }

    /// Records which boards a freshly fetched directory says are user-made.
    ///
    /// The list below is a floor, not a ceiling: readers create 2ch boards, and
    /// one made last week is in no table written today. `BoardsRepository` calls
    /// this every time it caches a directory, so a new board is covered as soon
    /// as the list has been fetched once — while the static table still covers
    /// the board a route is seeded with before anything has been fetched.
    public static func learn(userBoardCodes: Set<String>, on site: Imageboard) {
        learned.set(userBoardCodes, for: site)
    }

    /// Forgets what was learned. For tests, which must not leak into each other.
    public static func forgetLearnedBoards() {
        learned.clear()
    }

    private static let learned = LearnedUserBoards()

    /// 4chan's own not-worksafe set, as of 2026-09-17.
    ///
    /// Kept although ``Board/isWorkSafe`` reports the same thing, because the
    /// code-only form has no `Board` to ask.
    private static let fourchan: Set<String> = [
        "aco", "b", "bant", "d", "e", "f", "gif", "h", "hc", "hm",
        "hr", "i", "ic", "pol", "r", "r9k", "s", "s4s", "soc", "t",
        "trash", "u", "wg", "y",
    ]

    /// 2ch has no flag to read, so this is the whole of the answer there.
    ///
    /// Three groups: the site's own `Взрослым` category, every user-made board,
    /// and the dumping grounds filed under `Разное`. `/abu/`, `/media/` and
    /// `/man/` share that category and are deliberately left out of it.
    private static let dvach: Set<String> = [
        // Взрослым
        "e", "fag", "fet", "fg", "fur", "ga", "gg", "h", "hc", "ho",
        "nf", "sex", "vape",

        // Разное
        "b", "d", "r", "soc",

        // Пользовательские
        "2d", "8", "aa", "alco", "asmr", "br", "brg", "by", "ch",
        "char", "crypt", "cul", "cute", "dom", "dr", "electrach",
        "es", "ew", "fem", "fi", "fs", "gabe", "gb", "got", "gsg",
        "hg", "hh", "hv", "ind", "ing", "int", "izd", "jsf", "kz",
        "lap", "law", "ld", "m", "math", "mc", "mlpr", "nvr", "obr",
        "old", "out", "ph", "pvc", "qtr4", "r34", "rm", "ro", "sad",
        "se", "smo", "socionics", "srv", "sw", "t", "td", "to", "tr",
        "trv", "ukr", "ussr", "vr", "web", "whn", "who", "wow", "wwe",
        "ya",
    ]
}

/// The user-made boards seen in a directory this session.
///
/// `Mutex`-backed because `MatureBoards` is asked from repository actors and
/// from the main actor alike, and a static needs to be safe for both.
private final class LearnedUserBoards: Sendable {
    private let storage = Mutex<[Imageboard: Set<String>]>([:])

    func contains(site: Imageboard, code: String) -> Bool {
        storage.withLock { $0[site]?.contains(code) ?? false }
    }

    func codes(for site: Imageboard) -> Set<String> {
        storage.withLock { $0[site] ?? [] }
    }

    func set(_ codes: Set<String>, for site: Imageboard) {
        storage.withLock { $0[site] = codes }
    }

    func clear() {
        storage.withLock { $0.removeAll() }
    }
}
