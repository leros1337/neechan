import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Backup document")
struct BackupCodecTests {
    private func sampleBackup() -> NeechanBackup {
        NeechanBackup(
            favorites: [
                .init(
                    board: "b", threadNum: 1, title: "Тред", customTitle: "Моё",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000), isWatched: true
                ),
            ],
            favoriteBoards: ["b", "po"],
            history: [
                .init(
                    board: "po", threadNum: 2, title: "История",
                    visitedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
            ],
            autohideRules: [
                .init(
                    pattern: "спам", isRegularExpression: false, matchesSubject: false,
                    matchesComment: true, matchesName: false, matchesFileName: false,
                    boards: ["b"], appliesToOriginalPostOnly: false,
                    appliesToSagedOnly: false, isEnabled: true
                ),
            ],
            hiddenThreads: [.init(board: "b", threadNum: 3, title: "Скрытый")],
            settings: ["domain": "2ch.org"]
        )
    }

    @Test("a backup survives a round trip unchanged")
    func roundTrip() throws {
        let original = sampleBackup()
        let decoded = try BackupCodec.decode(try BackupCodec.encode(original))

        #expect(decoded.favorites == original.favorites)
        #expect(decoded.favoriteBoards == original.favoriteBoards)
        #expect(decoded.history == original.history)
        #expect(decoded.autohideRules == original.autohideRules)
        #expect(decoded.hiddenThreads == original.hiddenThreads)
        #expect(decoded.settings == original.settings)
    }

    @Test("the document is readable text, not an opaque blob")
    func isReadableJSON() throws {
        let data = try BackupCodec.encode(sampleBackup())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"favorites\""))
        #expect(text.contains("спам"))
        // Dates are written in a form other tools understand.
        #expect(text.contains("2023-"))
    }

    @Test("something that is not a backup is refused")
    func rejectsForeignFile() {
        #expect(throws: BackupCodec.DecodeError.notABackup) {
            _ = try BackupCodec.decode(Data(#"{"hello":"world"}"#.utf8))
        }
    }

    @Test("a file from a newer app is refused rather than half-read")
    func rejectsNewerVersion() throws {
        var backup = sampleBackup()
        backup.version = NeechanBackup.currentVersion + 1
        let data = try BackupCodec.encode(backup)

        #expect(throws: BackupCodec.DecodeError.self) {
            _ = try BackupCodec.decode(data)
        }
    }

    @Test("the suggested file name carries the date")
    func fileName() {
        let name = BackupCodec.suggestedFileName(
            for: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(name.hasPrefix("Neechan-"))
        #expect(name.hasSuffix(".json"))
        #expect(name.contains("2023-11"))
    }
}

@Suite("Backup service")
struct BackupServiceTests {
    private func makeServices() throws -> (BackupService, FavoritesRepository, HiddenContentRepository) {
        let container = try NeechanStore.makeContainer(inMemory: true)
        return (
            BackupService(modelContainer: container),
            FavoritesRepository(modelContainer: container),
            HiddenContentRepository(modelContainer: container)
        )
    }

    @Test("an export carries what the reader built up")
    func exportsUserData() async throws {
        let (backup, favorites, hidden) = try makeServices()
        try await favorites.add(ThreadKey(site: .dvach, board: "b", threadNum: 1), title: "Тред")
        try await favorites.addBoard(BoardRef(site: .dvach, code: "po"), name: "Политика")
        try await hidden.addRule(AutohideRuleValue(pattern: "спам", matchesComment: true))

        let document = try await backup.export(settings: ["domain": "2ch.org"])
        #expect(document.favorites.count == 1)
        #expect(document.favoriteBoards == ["po"])
        #expect(document.autohideRules.count == 1)
        #expect(document.settings["domain"] == "2ch.org")
    }

    @Test("an import adds what is missing without duplicating what is there")
    func importMerges() async throws {
        let (backup, favorites, _) = try makeServices()
        try await favorites.add(ThreadKey(site: .dvach, board: "b", threadNum: 1), title: "Уже есть")

        let document = NeechanBackup(
            favorites: [
                .init(board: "b", threadNum: 1, title: "Дубликат", customTitle: nil,
                      createdAt: .now, isWatched: true),
                .init(board: "b", threadNum: 2, title: "Новый", customTitle: nil,
                      createdAt: .now, isWatched: true),
            ],
            favoriteBoards: ["po"]
        )
        let summary = try await backup.import(document)

        #expect(summary.favorites == 1, "only the thread that was missing is added")
        #expect(summary.favoriteBoards == 1)
        #expect(try await favorites.favorites(site: .dvach).count == 2)
    }

    @Test("importing the same file twice changes nothing the second time")
    func importIsIdempotent() async throws {
        let (backup, _, _) = try makeServices()
        let document = NeechanBackup(
            favorites: [
                .init(board: "b", threadNum: 1, title: "Тред", customTitle: nil,
                      createdAt: .now, isWatched: true),
            ]
        )
        #expect(try await backup.import(document).total == 1)
        #expect(try await backup.import(document).total == 0)
    }
}

@Suite("Saved threads")
struct SavedThreadsRepositoryTests {
    private func makeRepository() throws -> SavedThreadsRepository {
        SavedThreadsRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    /// Saved threads share one folder on disk, and the suite runs in parallel,
    /// so each test saves under a board nobody else is using.
    private func uniqueKey() -> ThreadKey {
        ThreadKey(site: .dvach, board: "test-\(UUID().uuidString)", threadNum: 1)
    }

    @Test("a saved thread can be read back without a network")
    func saveAndLoad() async throws {
        let repository = try makeRepository()
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let rawJSON = try FixtureLoader.data(.thread)
        let key = uniqueKey()

        let item = try await repository.save(
            response,
            rawJSON: rawJSON,
            key: key,
            endpoints: SiteEndpoints(.default),
            // No media is fetched, so the test stays offline.
            policy: .thumbnails,
            downloader: OfflineDownloader()
        )
        #expect(item.postsCount == response.posts.count)
        #expect(try await repository.isSaved(key))

        let loaded = try await repository.load(key)
        #expect(loaded?.posts.count == response.posts.count)
        #expect(loaded?.title == response.title)

        try await repository.remove(key)
    }

    @Test("an unsaved thread loads as nothing")
    func loadMissing() async throws {
        let repository = try makeRepository()
        #expect(try await repository.load(ThreadKey(site: .dvach, board: "b", threadNum: 999)) == nil)
    }

    @Test("removing a saved thread takes its files with it")
    func removeDeletesFiles() async throws {
        let repository = try makeRepository()
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let key = uniqueKey()

        _ = try await repository.save(
            response, rawJSON: try FixtureLoader.data(.thread), key: key,
            endpoints: SiteEndpoints(.default), policy: .thumbnails, downloader: OfflineDownloader()
        )
        try await repository.remove(key)

        #expect(try await repository.isSaved(key) == false)
        #expect(try await repository.load(key) == nil)
        #expect(try await repository.saved(site: .dvach).isEmpty)
    }

    @Test("a server path becomes one flat file name")
    func flatFileNames() {
        let name = SavedThreadsRepository.fileName(for: "/po/src/123/456.jpg")
        #expect(name.contains("/") == false)
        #expect(name.hasSuffix(".jpg"))
    }
}

/// A fetcher that never reaches the network, so the saving tests stay offline.
private struct OfflineDownloader: MediaFetching {
    func data(_ url: URL, referer: URL?) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

/// A backup written before there were two imageboards.
///
/// The trap this guards: `Codable`'s generated decoder throws `keyNotFound` for
/// a missing key whatever default the property carries, and `decode` turns any
/// throw into "not a backup" — so a non-optional `site` would have made every
/// file an existing reader holds unreadable, and told them it was not a backup.
@Suite("Backup compatibility")
struct BackupCompatibilityTests {
    private let version1File = """
    {
      "version": 1,
      "exportedAt": "2026-01-01T00:00:00Z",
      "favorites": [
        {"board": "b", "threadNum": 1, "title": "Тред",
         "createdAt": "2026-01-01T00:00:00Z", "isWatched": true}
      ],
      "favoriteBoards": ["po"],
      "history": [
        {"board": "b", "threadNum": 2, "title": "Кот",
         "visitedAt": "2026-01-01T00:00:00Z"}
      ],
      "autohideRules": [
        {"pattern": "spam", "isRegularExpression": false, "matchesSubject": false,
         "matchesComment": true, "matchesName": false, "matchesFileName": false,
         "boards": [], "appliesToOriginalPostOnly": false,
         "appliesToSagedOnly": false, "isEnabled": true}
      ],
      "hiddenThreads": [{"board": "b", "threadNum": 3, "title": "Спам"}],
      "settings": {}
    }
    """

    @Test("a backup written before there were two imageboards still reads")
    func version1StillDecodes() throws {
        let backup = try BackupCodec.decode(Data(version1File.utf8))
        #expect(backup.version == 1)
        #expect(backup.favorites.count == 1)
        #expect(backup.favoriteBoards == ["po"])
        // Absent everywhere, and read as 2ch's, which is what it was.
        #expect(backup.favorites.first?.site == nil)
        #expect(backup.favorites.first?.key.site == .dvach)
        #expect(backup.history.first?.key.site == .dvach)
        #expect(backup.hiddenThreads.first?.key.site == .dvach)
    }

    @Test("importing one attributes everything to 2ch")
    func version1ImportsAsDvach() async throws {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let service = BackupService(modelContainer: container)
        let favorites = FavoritesRepository(modelContainer: container)

        let summary = try await service.import(BackupCodec.decode(Data(version1File.utf8)))
        #expect(summary.total > 0)

        #expect(try await favorites.favorites(site: .dvach).count == 1)
        #expect(try await favorites.favorites(site: .fourchan).isEmpty)
        #expect(try await favorites.favoriteBoards(site: .dvach).map(\.board) == ["po"])
    }

    /// A rule is not a record of something done on a site, so it keeps working
    /// on both rather than being narrowed to the one that existed when it was
    /// written.
    @Test("a rule from an older backup applies on every imageboard")
    func importedRulesStaySiteBlind() async throws {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let service = BackupService(modelContainer: container)
        let hidden = HiddenContentRepository(modelContainer: container)

        _ = try await service.import(BackupCodec.decode(Data(version1File.utf8)))
        let rule = try #require(try await hidden.rules().first)
        #expect(rule.sites.isEmpty)
    }

    @Test("a backup this build writes carries the imageboard on every entry")
    func version2CarriesTheSite() async throws {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let favorites = FavoritesRepository(modelContainer: container)
        let service = BackupService(modelContainer: container)

        try await favorites.add(
            ThreadKey(site: .fourchan, board: "g", threadNum: 1), title: "Fourchan"
        )
        let document = try await service.export(settings: [:])

        #expect(document.version == 2)
        #expect(document.favorites.first?.site == "fourchan")
        #expect(document.favorites.first?.key.site == .fourchan)
    }

    /// Round trip: a file this build writes, read back by this build, puts
    /// everything back where it came from.
    @Test("a backup round-trips without losing which imageboard anything was on")
    func roundTrip() async throws {
        let source = try NeechanStore.makeContainer(inMemory: true)
        let sourceFavorites = FavoritesRepository(modelContainer: source)
        try await sourceFavorites.add(ThreadKey(site: .dvach, board: "b", threadNum: 1), title: "Двач")
        try await sourceFavorites.add(ThreadKey(site: .fourchan, board: "b", threadNum: 1), title: "Fourchan")
        let document = try await BackupService(modelContainer: source).export(settings: [:])

        let destination = try NeechanStore.makeContainer(inMemory: true)
        _ = try await BackupService(modelContainer: destination).import(
            try BackupCodec.decode(try BackupCodec.encode(document))
        )

        let restored = FavoritesRepository(modelContainer: destination)
        #expect(try await restored.favorites(site: .dvach).map(\.title) == ["Двач"])
        #expect(try await restored.favorites(site: .fourchan).map(\.title) == ["Fourchan"])
    }
}
