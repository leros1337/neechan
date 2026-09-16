import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("History repository")
struct HistoryRepositoryTests {
    private func makeRepository() throws -> HistoryRepository {
        HistoryRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    @Test("visiting a thread records it")
    func recordsVisit() async throws {
        let repository = try makeRepository()
        try await repository.recordVisit(
            ThreadKey(board: "b", threadNum: 1), title: "Тред", thumbnailPath: "/b/thumb/1/1s.jpg"
        )

        let entries = try await repository.recent(limit: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.key == ThreadKey(board: "b", threadNum: 1))
        #expect(entries.first?.title == "Тред")
        #expect(entries.first?.thumbnailPath == "/b/thumb/1/1s.jpg")
    }

    @Test("visiting the same thread twice updates it rather than duplicating")
    func visitIsIdempotent() async throws {
        let repository = try makeRepository()
        let key = ThreadKey(board: "b", threadNum: 1)
        try await repository.recordVisit(key, title: "Старое название")
        try await repository.recordVisit(key, title: "Новое название")

        let entries = try await repository.recent(limit: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Новое название")
    }

    @Test("the most recently visited thread comes first")
    func ordersByRecency() async throws {
        let repository = try makeRepository()
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 1), title: "Первый")
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 2), title: "Второй")
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 1), title: "Первый снова")

        let entries = try await repository.recent(limit: 10)
        #expect(entries.map(\.key.threadNum) == [1, 2])
    }

    @Test("the limit is honoured")
    func honoursLimit() async throws {
        let repository = try makeRepository()
        for num in 1...5 {
            try await repository.recordVisit(ThreadKey(board: "b", threadNum: num), title: "#\(num)")
        }
        #expect(try await repository.recent(limit: 3).count == 3)
    }

    @Test("an entry can be removed")
    func removesEntry() async throws {
        let repository = try makeRepository()
        let key = ThreadKey(board: "b", threadNum: 1)
        try await repository.recordVisit(key, title: "Тред")
        try await repository.remove(key)
        #expect(try await repository.recent(limit: 10).isEmpty)
    }

    @Test("history can be cleared")
    func clearsAll() async throws {
        let repository = try makeRepository()
        for num in 1...3 {
            try await repository.recordVisit(ThreadKey(board: "b", threadNum: num), title: "#\(num)")
        }
        try await repository.clear()
        #expect(try await repository.recent(limit: 10).isEmpty)
    }

    @Test("threads on different boards with the same number are distinct")
    func boardIsPartOfIdentity() async throws {
        let repository = try makeRepository()
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 1), title: "Б")
        try await repository.recordVisit(ThreadKey(board: "po", threadNum: 1), title: "По")
        #expect(try await repository.recent(limit: 10).count == 2)
    }

    @Test("history can be searched by title")
    func searchesByTitle() async throws {
        let repository = try makeRepository()
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 1), title: "Котики")
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 2), title: "Собаки")

        let hits = try await repository.search("кот", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Котики")
    }

    @Test("recording can be switched off, for users who do not want a history")
    func respectsDisabledRecording() async throws {
        let repository = try makeRepository()
        await repository.setRecordingEnabled(false)
        try await repository.recordVisit(ThreadKey(board: "b", threadNum: 1), title: "Тред")
        #expect(try await repository.recent(limit: 10).isEmpty)
    }
}

@Suite("Store")
struct StoreTests {
    @Test("an in-memory container builds with the full schema")
    func buildsContainer() throws {
        _ = try NeechanStore.makeContainer(inMemory: true)
    }

    @Test("the schema is versioned so future migrations have a starting point")
    func schemaIsVersioned() {
        #expect(NeechanSchemaV1.versionIdentifier.description.isEmpty == false)
        #expect(NeechanSchemaV1.models.isEmpty == false)
    }
}
