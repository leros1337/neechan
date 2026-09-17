import Foundation
import NeechanAPI
import Testing
@testable import NeechanCore

@Suite("Mature boards")
struct MatureBoardsTests {
    /// The list a reader is actually judged against, pinned so a stray edit to
    /// the table shows up as a failure rather than as a board quietly becoming
    /// reachable.
    @Test("4chan's set is the boards 4chan itself calls not worksafe")
    func fourchanSet() {
        let expected: Set<String> = [
            "aco", "b", "bant", "d", "e", "f", "gif", "h", "hc", "hm", "hr", "i",
            "ic", "pol", "r", "r9k", "s", "s4s", "soc", "t", "trash", "u", "wg", "y",
        ]
        #expect(MatureBoards.codes(on: .fourchan) == expected)
    }

    @Test("2ch's set covers the adult category, the user boards and the dumps")
    func dvachSet() {
        let codes = MatureBoards.codes(on: .dvach)
        // Взрослым
        #expect(codes.isSuperset(of: ["h", "hc", "sex", "fet", "e", "fur", "nf"]))
        // Пользовательские, which is the whole category
        #expect(codes.isSuperset(of: ["r34", "ya", "hg", "mc", "wow", "math"]))
        // Разное, the four named ones and not the other three
        #expect(codes.isSuperset(of: ["b", "d", "r", "soc"]))
        #expect(codes.isDisjoint(with: ["abu", "media", "man"]))
        // A plain themed board is untouched.
        #expect(!codes.contains("vg"))
    }

    /// The two sites reuse each other's codes for entirely different boards, so
    /// a code can only ever be judged against its own site.
    @Test("a code is judged against its own site")
    func codesAreJudgedPerSite() {
        // Sexy Beautiful Women on 4chan; Программы, which is software, on 2ch.
        #expect(MatureBoards.contains("s", on: .fourchan))
        #expect(!MatureBoards.contains("s", on: .dvach))
        // Меха, a user-made board, on 2ch; plain Mecha on 4chan.
        #expect(MatureBoards.contains("m", on: .dvach))
        #expect(!MatureBoards.contains("m", on: .fourchan))
        // Both sites keep a /b/ and both mean it.
        #expect(MatureBoards.contains("b", on: .dvach))
        #expect(MatureBoards.contains("b", on: .fourchan))
    }

    @Test("however the code was written, it is the same board")
    func codesAreCleaned() {
        for written in ["hc", "HC", "/hc/", " /Hc/ ", "hc/"] {
            #expect(MatureBoards.contains(written, on: .dvach), "\(written) was not recognised")
        }
        #expect(!MatureBoards.contains("", on: .dvach))
        #expect(!MatureBoards.contains("//", on: .dvach))
    }

    /// The belt for a board 4chan adds after this table was written.
    @Test("a board the table has not heard of is judged by the site's own flag")
    func theSiteSownFlagIsTheBelt() {
        let newAdultBoard = Board(id: "zz", name: "New", category: "NSFW", isWorkSafe: false)
        #expect(MatureBoards.contains(newAdultBoard, on: .fourchan))
        #expect(!MatureBoards.contains("zz", on: .fourchan), "the table alone should not know it")

        let worksafe = Board(id: "yy", name: "New", category: "Worksafe", isWorkSafe: true)
        #expect(!MatureBoards.contains(worksafe, on: .fourchan))
    }

    /// 2ch reports every board as worksafe, so the flag must not be able to
    /// overrule the table there — in either direction.
    @Test("2ch's hardcoded worksafe flag leaves the table in charge")
    func dvachIsDecidedByTheTable() {
        let hardcore = Board(id: "hc", name: "Hardcore", category: "Взрослым", isWorkSafe: true)
        #expect(MatureBoards.contains(hardcore, on: .dvach))
    }

    @Test("a user board created after this table was written is still covered")
    func learnedUserBoardsAreCovered() {
        defer { MatureBoards.forgetLearnedBoards() }

        #expect(!MatureBoards.contains("brandnew", on: .dvach))
        MatureBoards.learn(userBoardCodes: ["brandnew"], on: .dvach)
        #expect(MatureBoards.contains("brandnew", on: .dvach))
        // Learned for one site only.
        #expect(!MatureBoards.contains("brandnew", on: .fourchan))

        MatureBoards.forgetLearnedBoards()
        #expect(!MatureBoards.contains("brandnew", on: .dvach))
    }
}

@Suite("Content policy")
struct ContentPolicyTests {
    private let blocked = ContentPolicy(allowsMatureBoards: false)

    @Test("the default policy allows everything, including a listed board")
    func unrestrictedAllowsEverything() {
        #expect(ContentPolicy.unrestricted.allowsMatureBoards)
        #expect(ContentPolicy.unrestricted.allows(code: "hc", on: .dvach))
        #expect(ContentPolicy.unrestricted.allows(code: "b", on: .fourchan))
    }

    @Test("with the gate on, only the listed boards are refused")
    func theGateRefusesOnlyWhatIsListed() {
        #expect(!blocked.allows(code: "hc", on: .dvach))
        #expect(!blocked.allows(code: "b", on: .dvach))
        #expect(blocked.allows(code: "vg", on: .dvach))
        #expect(blocked.allows(code: "a", on: .fourchan))
    }

    /// The reason `allows` takes a key rather than a code and a current site.
    @Test("a thread key is judged on its own site, not the selected one")
    func aKeyCarriesItsOwnSite() {
        let sexyWomenOn4chan = ThreadKey(site: .fourchan, board: "s", threadNum: 1)
        let softwareOn2ch = ThreadKey(site: .dvach, board: "s", threadNum: 1)

        #expect(!blocked.allows(sexyWomenOn4chan))
        #expect(blocked.allows(softwareOn2ch))

        #expect(!blocked.allows(BoardRef(site: .fourchan, code: "s")))
        #expect(blocked.allows(BoardRef(site: .dvach, code: "s")))
    }

    @Test("filtering a directory drops the restricted boards and keeps the rest")
    func filteringADirectory() {
        let boards = [
            Board(id: "vg", name: "Games", category: "Игры"),
            Board(id: "hc", name: "Hardcore", category: "Взрослым"),
            Board(id: "b", name: "Бред", category: "Разное"),
            Board(id: "a", name: "Аниме", category: "Японская культура"),
        ]

        #expect(ContentPolicy.unrestricted.filter(boards, on: .dvach).count == 4)
        #expect(blocked.filter(boards, on: .dvach).map(\.id) == ["vg", "a"])
    }
}
