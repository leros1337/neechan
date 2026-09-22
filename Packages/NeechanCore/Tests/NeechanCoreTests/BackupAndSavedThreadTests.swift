import Foundation
import NeechanAPI
import Synchronization
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

    /// The gap that kept saving off on 4chan, and the reason it was invisible:
    /// the 2ch test above feeds one fixture in both as a decoded `ThreadResponse`
    /// and as raw bytes, which is a coincidence that holds on 2ch alone. 4chan's
    /// file is `{"posts": […]}` and has to be mapped to become posts at all.
    @Test("a 4chan thread can be read back without a network")
    func saveAndLoadFourchan() async throws {
        let repository = try makeRepository()
        let selection = SiteSelection(site: .fourchan)
        let rawJSON = try FixtureLoader.data(.fourchanThread)
        // Through the same seam the archiver reads with, which is the only way
        // to a 4chan `ThreadResponse` from outside NeechanAPI.
        let response = try StoredThread.response(
            from: rawJSON,
            on: selection,
            board: Board(id: "a", defaultName: "Anonymous")
        )
        #expect(response.posts.isEmpty == false, "the fixture decoded to nothing")

        let key = ThreadKey(site: .fourchan, board: "test-\(UUID().uuidString)", threadNum: 1)
        _ = try await repository.save(
            response,
            rawJSON: rawJSON,
            key: key,
            endpoints: selection.endpoints,
            policy: .thumbnails,
            downloader: OfflineDownloader()
        )

        let loaded = try await repository.load(key)
        #expect(loaded?.posts.count == response.posts.count)
        #expect(loaded?.posts.first?.num == response.posts.first?.num)

        try await repository.remove(key)
    }

    /// What the V2 schema migration existed for, and never had a test: the two
    /// sites' `/a/123` are two threads.
    @Test("the same board and number on two sites are two saved threads")
    func sitesDoNotCollide() async throws {
        let repository = try makeRepository()
        let board = "test-\(UUID().uuidString)"
        let dvach = ThreadKey(site: .dvach, board: board, threadNum: 1)
        let fourchan = ThreadKey(site: .fourchan, board: board, threadNum: 1)

        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let rawJSON = try FixtureLoader.data(.thread)
        for key in [dvach, fourchan] {
            _ = try await repository.save(
                response,
                rawJSON: rawJSON,
                key: key,
                endpoints: SiteEndpoints(.default),
                policy: .thumbnails,
                downloader: OfflineDownloader()
            )
        }

        #expect(try await repository.isSaved(dvach))
        #expect(try await repository.isSaved(fourchan))
        #expect(try await repository.saved(site: .dvach).count == 1)
        #expect(try await repository.saved(site: .fourchan).count == 1)

        // Removing one leaves the other, which is the point of the constraint.
        try await repository.remove(dvach)
        #expect(try await repository.isSaved(dvach) == false)
        #expect(try await repository.isSaved(fourchan))

        try await repository.remove(fourchan)
    }

    /// The point of downloading them at all. These were being written and never
    /// read: a saved thread still asked the site for every thumbnail, so
    /// "offline" meant the text and nothing else.
    @Test("a saved thread's attachments point at the files kept beside it")
    func loadedAttachmentsPointAtDisk() async throws {
        let repository = try makeRepository()
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let rawJSON = try FixtureLoader.data(.thread)
        let key = uniqueKey()

        _ = try await repository.save(
            response,
            rawJSON: rawJSON,
            key: key,
            endpoints: SiteEndpoints(.default),
            policy: .thumbnails,
            downloader: BytesDownloader()
        )

        let loaded = try #require(try await repository.load(key))
        let files = loaded.posts.flatMap(\.files)
        try #require(files.isEmpty == false)

        for file in files {
            let thumbnail = try #require(URL(string: file.thumbnail))
            #expect(thumbnail.isFileURL, "a thumbnail still points at the site")
            #expect(
                FileManager.default.fileExists(atPath: thumbnail.path),
                "a thumbnail points at a file that is not there"
            )
        }

        // Thumbnails only: the full files were never fetched, so they must
        // still name the site rather than a path with nothing behind it.
        for file in files {
            #expect(
                URL(string: file.path)?.isFileURL != true,
                "a full file was repointed at a copy that was never saved"
            )
        }

        try await repository.remove(key)
    }

    /// With everything kept, the full files are on disk too.
    @Test("a full save points the files at disk as well as the thumbnails")
    func fullSavePointsFilesAtDisk() async throws {
        let repository = try makeRepository()
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let rawJSON = try FixtureLoader.data(.thread)
        let key = uniqueKey()

        _ = try await repository.save(
            response,
            rawJSON: rawJSON,
            key: key,
            endpoints: SiteEndpoints(.default),
            policy: .fullFiles,
            downloader: BytesDownloader()
        )

        let loaded = try #require(try await repository.load(key))
        for file in loaded.posts.flatMap(\.files) {
            #expect(URL(string: file.path)?.isFileURL == true, "a full file still points at the site")
            #expect(URL(string: file.thumbnail)?.isFileURL == true)
        }

        try await repository.remove(key)
    }

    @Test("progress counts every file and ends on the total")
    func progressReportsEveryFile() async throws {
        let repository = try makeRepository()
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let rawJSON = try FixtureLoader.data(.thread)
        let key = uniqueKey()
        let total = response.posts.flatMap(\.files).count
        try #require(total > 0, "the fixture has no files to count")

        // The count moves per attachment whether or not its bytes arrived, so
        // an offline downloader still exercises the whole sequence.
        let counts = Mutex<[Int]>([])
        let totals = Mutex<Set<Int>>([])
        _ = try await repository.save(
            response,
            rawJSON: rawJSON,
            key: key,
            endpoints: SiteEndpoints(.default),
            policy: .thumbnails,
            downloader: OfflineDownloader(),
            onProgress: { done, reported in
                counts.withLock { $0.append(done) }
                totals.withLock { $0.insert(reported) }
            }
        )

        #expect(counts.withLock { $0 } == Array(1...total), "the count skipped or repeated")
        #expect(totals.withLock { $0 } == [total], "the total moved while saving")

        try await repository.remove(key)
    }

    /// The guarantee that makes cancelling safe, and the reason the JSON is
    /// written before anything is fetched: an interrupted save leaves a
    /// readable thread rather than an empty folder.
    ///
    /// Asserted as an ordering invariant rather than by racing a real
    /// cancellation, which would need a hook into the middle of the download
    /// loop and would be timing-dependent either way.
    @Test("the thread is on disk before the first file is fetched")
    func jsonIsWrittenBeforeMedia() async throws {
        let repository = try makeRepository()
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let rawJSON = try FixtureLoader.data(.thread)
        let key = uniqueKey()
        try #require(response.posts.flatMap(\.files).isEmpty == false)

        let jsonURL = SavedThreadsRepository.rootDirectory
            .appending(path: key.identifier)
            .appending(path: "thread.json")
        let downloader = ThreadWatchingDownloader(jsonURL: jsonURL)

        _ = try await repository.save(
            response,
            rawJSON: rawJSON,
            key: key,
            endpoints: SiteEndpoints(.default),
            policy: .thumbnails,
            downloader: downloader
        )

        #expect(
            downloader.sawJSON.withLock { $0 } == true,
            "media was fetched before the thread was readable"
        )

        try await repository.remove(key)
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

/// Notes whether the thread's JSON was already on disk when the first file was
/// asked for, then refuses like the offline stub.
private final class ThreadWatchingDownloader: MediaFetching {
    let sawJSON = Mutex<Bool?>(nil)
    private let jsonURL: URL

    init(jsonURL: URL) {
        self.jsonURL = jsonURL
    }

    func data(_ url: URL, referer: URL?) async throws -> Data {
        sawJSON.withLock { seen in
            guard seen == nil else { return }
            seen = FileManager.default.fileExists(atPath: jsonURL.path)
        }
        throw URLError(.notConnectedToInternet)
    }
}

/// A fetcher that answers with bytes instead of reaching the network, so a test
/// can have real files on disk without one.
private struct BytesDownloader: MediaFetching {
    func data(_ url: URL, referer: URL?) async throws -> Data {
        Data("saved".utf8)
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
