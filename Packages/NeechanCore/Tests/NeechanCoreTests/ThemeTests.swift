import Foundation
import NeechanAPI
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Theme decoding")
struct ThemeJSONDecoderTests {
    @Test("a Dashchan theme file becomes a theme")
    func decodesDashchanTheme() throws {
        let theme = try ThemeJSONDecoder.decode(FixtureLoader.data(.themeDashchan))

        #expect(theme.name == "Neechan Night")
        #expect(theme.isDark, "a near-black window colour reads as a dark theme")
        #expect(theme.accent == ThemeColor(red: 0x4F / 255, green: 0xA3 / 255, blue: 1))
    }

    /// Dashchan writes `#AARRGGBB`, which puts the alpha where the web puts red.
    @Test("colours are read alpha first, the way Android writes them")
    func alphaComesFirst() throws {
        let theme = try ThemeJSONDecoder.decode(Data(##"{"name":"t","accent":"#80ff0000"}"##.utf8))

        #expect(theme.accent == ThemeColor(red: 1, green: 0, blue: 0, opacity: 128 / 255))
    }

    @Test(
        "every colour spelling Android accepts is understood",
        arguments: [
            ("#f00", ThemeColor(red: 1, green: 0, blue: 0)),
            ("#ff0000", ThemeColor(red: 1, green: 0, blue: 0)),
            ("#ffff0000", ThemeColor(red: 1, green: 0, blue: 0)),
            ("ff0000", ThemeColor(red: 1, green: 0, blue: 0)),
        ]
    )
    func colourSpellings(spelling: String, expected: ThemeColor) throws {
        #expect(ThemeColor(cssLike: spelling) == expected)
    }

    @Test("a missing colour keeps the built-in one rather than turning black")
    func missingColoursFallBack() throws {
        let theme = try ThemeJSONDecoder.decode(Data(##"{"name":"Sparse"}"##.utf8))

        #expect(theme.name == "Sparse")
        #expect(theme.accent == NeechanTheme.builtIn.accent)
        #expect(theme.postText == NeechanTheme.builtIn.postText)
    }

    @Test("a file that is not a theme is refused")
    func rejectsNonThemes() {
        #expect(throws: ThemeJSONDecoder.DecodingFailure.self) {
            try ThemeJSONDecoder.decode(Data("not json at all".utf8))
        }
        #expect(throws: ThemeJSONDecoder.DecodingFailure.self) {
            try ThemeJSONDecoder.decode(Data(##"{"accent":"#fff"}"##.utf8))
        }
    }

    @Test("a light window colour reads as a light theme")
    func lightThemesAreDetected() throws {
        let theme = try ThemeJSONDecoder.decode(
            Data(##"{"name":"Day","window":"#fff8f8f8"}"##.utf8)
        )
        #expect(theme.isDark == false)
    }

    @Test("a decoded theme survives a round trip through storage")
    func roundTrip() throws {
        let theme = try ThemeJSONDecoder.decode(FixtureLoader.data(.themeDashchan))
        let data = try JSONEncoder().encode(theme)

        #expect(try JSONDecoder().decode(NeechanTheme.self, from: data) == theme)
    }
}

@Suite("Built-in themes")
struct BuiltInThemeTests {
    @Test("the app ships more than one scheme to choose from")
    func shipsSeveral() {
        #expect(NeechanTheme.builtIns.count >= 5)
        #expect(NeechanTheme.builtIns.first == .builtIn, "the system look stays the first row")
    }

    @Test("every built-in is marked as one, and imported themes are not")
    func builtInsAreMarked() throws {
        for theme in NeechanTheme.builtIns {
            #expect(theme.isBuiltIn, "\(theme.name) is not recognised as built in")
        }
        let imported = try ThemeJSONDecoder.decode(FixtureLoader.data(.themeDashchan))
        #expect(imported.isBuiltIn == false)
    }

    @Test("no two built-ins share an id or a name")
    func idsAreUnique() {
        #expect(Set(NeechanTheme.builtIns.map(\.id)).count == NeechanTheme.builtIns.count)
        #expect(Set(NeechanTheme.builtIns.map(\.name)).count == NeechanTheme.builtIns.count)
    }

    @Test("no two built-ins look the same, which would make the list pointless")
    func accentsDiffer() {
        let accents = Set(NeechanTheme.builtIns.map(\.accent))
        #expect(accents.count == NeechanTheme.builtIns.count)
    }

    @Test("both a light and a dark scheme are offered")
    func bothAppearances() {
        #expect(NeechanTheme.builtIns.contains { $0.isDark })
        #expect(NeechanTheme.builtIns.contains { !$0.isDark })
    }

    @Test("a built-in is found by its id")
    func lookup() throws {
        let midnight = try #require(NeechanTheme.builtIns.last)
        #expect(NeechanTheme.builtIn(id: midnight.id) == midnight)
        #expect(NeechanTheme.builtIn(id: "nothing.like.this") == nil)
    }
}

@Suite("Theme storage")
struct ThemeRepositoryTests {
    private func makeRepository() throws -> ThemeRepository {
        ThemeRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    @Test("an imported theme is listed after the built-in one")
    func importAndList() async throws {
        let repository = try makeRepository()
        let theme = try await repository.import(FixtureLoader.data(.themeDashchan))

        #expect(theme.name == "Neechan Night")
        let all = try await repository.themes()
        #expect(all.first == .builtIn)
        #expect(all.contains(theme))
        for builtIn in NeechanTheme.builtIns {
            #expect(all.contains(builtIn), "\(builtIn.name) is missing from the list")
        }
    }

    @Test("importing the same theme twice replaces it rather than duplicating")
    func importIsIdempotent() async throws {
        let repository = try makeRepository()
        _ = try await repository.import(FixtureLoader.data(.themeDashchan))
        _ = try await repository.import(FixtureLoader.data(.themeDashchan))

        #expect(
            try await repository.themes().count == NeechanTheme.builtIns.count + 1,
            "the built-ins plus one import"
        )
    }

    @Test("a removed theme is gone, and the built-in one cannot be removed")
    func remove() async throws {
        let repository = try makeRepository()
        let theme = try await repository.import(FixtureLoader.data(.themeDashchan))

        try await repository.remove(id: theme.id)
        #expect(try await repository.themes() == NeechanTheme.builtIns)

        // A built-in has no file behind it, so there is nothing to remove.
        try await repository.remove(id: NeechanTheme.builtIn.id)
        #expect(try await repository.themes() == NeechanTheme.builtIns)
    }

    @Test("asking for a theme that was deleted falls back to the built-in one")
    func lookupFallsBack() async throws {
        let repository = try makeRepository()
        #expect(try await repository.theme(id: "gone") == .builtIn)
        #expect(try await repository.theme(id: nil) == .builtIn)
    }

    @Test("a built-in is returned without anything having been imported")
    func builtInsResolveWithoutStorage() async throws {
        let repository = try makeRepository()
        let scheme = try #require(NeechanTheme.builtIns.dropFirst().first)

        #expect(try await repository.theme(id: scheme.id) == scheme)
    }
}

@Suite("Media load policy")
struct MediaLoadDecisionTests {
    @Test(
        "the policy decides, and only Wi-Fi only cares about the connection",
        arguments: [
            (MediaLoadPolicy.always, false, true),
            (.always, true, true),
            (.wifiOnly, false, true),
            (.wifiOnly, true, false),
            (.never, false, false),
            (.never, true, false),
        ]
    )
    func decisions(policy: MediaLoadPolicy, isExpensive: Bool, expected: Bool) {
        #expect(MediaLoadDecision.shouldLoad(policy: policy, isExpensive: isExpensive) == expected)
    }
}

@Suite("Paged browsing")
struct IndexPageTests {
    @Test("a board page's threads become catalog rows")
    func summaries() throws {
        let page = try FixtureLoader.decode(BoardPage.self, from: .indexPage0)
        let indexPage = CatalogRepository.IndexPage(
            board: page.board,
            threads: page.threads,
            currentPage: page.currentPage,
            pageCount: max(page.pages.count, 1),
            boardSpeed: page.boardSpeed
        )

        #expect(indexPage.summaries.count == page.threads.count)
        let first = try #require(indexPage.summaries.first)
        #expect(first.num == page.threads[0].threadNum)
        #expect(first.postsCount == page.threads[0].postsCount)
    }

    @Test("the last page has nothing after it")
    func lastPage() throws {
        let page = CatalogRepository.IndexPage(
            board: try FixtureLoader.decode(BoardPage.self, from: .indexPage0).board,
            threads: [],
            currentPage: 3,
            pageCount: 4,
            boardSpeed: nil
        )
        #expect(page.hasNextPage == false)
    }
}

@Suite("User boards")
struct UserBoardCategoryTests {
    @Test("the site's user boards are recognised in the board list")
    func findsUserBoards() throws {
        let boards = try FixtureLoader.decode([Board].self, from: .boards)
        let userBoards = BoardsRepository.userBoards(in: boards)

        #expect(userBoards.count > 10, "the site has dozens of user boards")
        #expect(userBoards.allSatisfy { BoardsRepository.isUserBoard($0) })
    }

    @Test("the main boards are not mistaken for user boards")
    func excludesMainBoards() throws {
        let boards = try FixtureLoader.decode([Board].self, from: .boards)
        let userBoards = Set(BoardsRepository.userBoards(in: boards).map(\.id))

        #expect(userBoards.contains("b") == false)
        #expect(userBoards.contains("po") == false)
    }

    @Test("they come back in the order the site lists them")
    func keepsOrder() throws {
        let boards = try FixtureLoader.decode([Board].self, from: .boards)
        let userBoards = BoardsRepository.userBoards(in: boards)
        let expected = boards.filter(BoardsRepository.isUserBoard).map(\.id)

        #expect(userBoards.map(\.id) == expected)
    }
}
