import Foundation

/// The headings 4chan groups its own board list under.
///
/// `boards.json` carries no category at all, and `BoardsRepository` groups the
/// drawer on `Board.category` — so without this the directory is one flat list
/// of seventy-seven rows, which is materially worse than the 2ch one beside it.
///
/// A static table because that is what the data is: it changes when 4chan adds
/// a board, which is roughly once a year. Anything unlisted falls back to
/// worksafe or not, so a new board appears in a sensible place rather than
/// vanishing into an unnamed group.
///
/// The headings are English because they are the site's own, exactly as the 2ch
/// categories that sit beside them are Russian. Neither is translated.
enum FourchanBoardCategories {
    static func category(for board: String, isWorkSafe: Bool) -> String {
        if let known = table[board] { return known }
        return isWorkSafe ? "Worksafe" : "NSFW"
    }

    private static let table: [String: String] = [
        // Japanese Culture
        "a": japaneseCulture, "c": japaneseCulture, "w": japaneseCulture,
        "m": japaneseCulture, "cgl": japaneseCulture, "cm": japaneseCulture,
        "f": japaneseCulture, "n": japaneseCulture, "jp": japaneseCulture,
        "vt": japaneseCulture,

        // Video Games
        "v": videoGames, "vg": videoGames, "vm": videoGames, "vmg": videoGames,
        "vp": videoGames, "vr": videoGames, "vrpg": videoGames, "vst": videoGames,
        "video": videoGames,

        // Interests
        "co": interests, "g": interests, "tv": interests, "k": interests,
        "o": interests, "an": interests, "tg": interests, "sp": interests,
        "xs": interests, "pw": interests, "sci": interests, "his": interests,
        "int": interests, "out": interests, "toy": interests,

        // Creative
        "i": creative, "po": creative, "p": creative, "ck": creative,
        "ic": creative, "wg": creative, "lit": creative, "mu": creative,
        "fa": creative, "3": creative, "gd": creative, "diy": creative,
        "wsg": creative, "qst": creative,

        // Other
        "biz": other, "trv": other, "fit": other, "x": other, "adv": other,
        "lgbt": other, "mlp": other, "news": other, "wsr": other, "vip": other,

        // Misc (NSFW)
        "b": miscNSFW, "r9k": miscNSFW, "pol": miscNSFW, "bant": miscNSFW,
        "soc": miscNSFW, "s4s": miscNSFW,

        // Adult (NSFW)
        "s": adult, "hc": adult, "hm": adult, "h": adult, "e": adult,
        "u": adult, "d": adult, "y": adult, "t": adult, "hr": adult,
        "gif": adult, "aco": adult, "r": adult, "trash": adult,
    ]

    private static let japaneseCulture = "Japanese Culture"
    private static let videoGames = "Video Games"
    private static let interests = "Interests"
    private static let creative = "Creative"
    private static let other = "Other"
    private static let miscNSFW = "Misc (NSFW)"
    private static let adult = "Adult (NSFW)"
}
