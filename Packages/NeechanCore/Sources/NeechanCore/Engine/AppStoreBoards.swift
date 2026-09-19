import Foundation
import NeechanAPI

/// The boards the App Store build lists: anime, manga, comics, and the art
/// boards around them.
///
/// A table of codes rather than a category name, because the two sites do not
/// agree on categories and neither answer would survive:
///
/// - **4chan** sends no category at all. The app fabricates one client-side in
///   `FourchanBoardCategories`, where `/co/` — Comics & Cartoons, the single
///   most on-topic board here — is filed under "Interests", and the hentai
///   boards sit under "Adult (NSFW)". No category name selects what is wanted.
/// - **2ch** sends a category, but as a Russian display string. Keying a
///   shipped build's board list on a string the server can reword at any time
///   would mean an empty catalogue and no way to tell why.
///
/// So: a code list, checked the way ``MatureBoards`` checks its own, and the
/// one place to edit the set.
///
/// This is deliberately *not* a claim about what is worksafe. It narrows the
/// directory to a subject; ``MatureBoards`` is still what decides whether a
/// board is for adults, and both questions are asked in ``ContentPolicy``.
public enum AppStoreBoards {
    /// Whether this code names a board the App Store build lists.
    ///
    /// Tolerant of how the code was written, for the same reason
    /// ``MatureBoards/contains(_:on:)-(String,_)`` is: a reader types `/A/`,
    /// a `ThreadKey` carries a bare `a`, and neither has been through
    /// ``BoardCode/normalized(_:for:)``.
    public static func contains(_ code: String, on site: Imageboard) -> Bool {
        let cleaned = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !cleaned.isEmpty else { return false }
        return codes(on: site).contains(cleaned)
    }

    public static func contains(_ board: Board, on site: Imageboard) -> Bool {
        contains(board.id, on: site)
    }

    public static func codes(on site: Imageboard) -> Set<String> {
        switch site {
        case .dvach: dvach
        case .fourchan: fourchan
        }
    }

    /// Read off 4chan's own board list.
    private static let fourchan: Set<String> = [
        // Anime and manga.
        "a",    // Anime & Manga
        "c",    // Anime/Cute
        "w",    // Anime/Wallpapers
        "m",    // Mecha
        "cgl",  // Cosplay & EGL
        "cm",   // Cute/Male
        "jp",   // Otaku Culture
        "vt",   // Virtual YouTubers
        // Comics.
        "co",   // Comics & Cartoons
        // The drawing boards around them. /i/ and /ic/ are deliberately absent:
        // 4chan reports both as not worksafe, so ``MatureBoards`` holds them
        // and listing them here would put a board in the directory that then
        // refused to open. ``AppStoreBoardsTests`` pins that invariant.
        "3",    // 3DCG
        "gd",   // Graphic Design
    ]

    /// 2ch's Японская культура section, plus the art boards.
    ///
    /// Worth re-checking against the live directory when it changes: unlike
    /// 4chan's, this list could not be read out of the repository, because the
    /// recorded fixture carries only one board per section.
    /// Shorter than 4chan's, and not for want of trying: 2ch has no first-party
    /// art boards. Every board a reader made — which is where /aa/ Аниме арт,
    /// /td/ Трёхмерная графика and /izd/ Графомания live — is adult-gated
    /// wholesale by ``MatureBoards``, as is /to/ Touhou, so naming any of them
    /// here would list a board that then refused to open.
    private static let dvach: Set<String> = [
        "a",    // Аниме
        "ma",   // Манга
        "fd",   // Фэндомы
        "vn",   // Визуальные новеллы
    ]
}
