import Foundation
import NeechanAPITesting
import Testing
@testable import NeechanCore

@Suite("Cached threads")
@MainActor
struct ThreadCacheTests {
    private func makeServices() throws -> AppServices {
        try AppServices.inMemory(transport: StubTransport())
    }

    private func key(_ num: Int) -> ThreadKey {
        ThreadKey(board: "b", threadNum: num)
    }

    @Test("a thread opened twice is the same repository, so it is not refetched")
    func repositoriesAreReused() throws {
        let services = try makeServices()

        let first = services.threadRepository(for: key(1))
        let second = services.threadRepository(for: key(1))

        #expect(first === second)
    }

    /// A repository holds every post in its thread and every parsed comment, so
    /// a session that wandered through thirty threads was holding all thirty.
    @Test("only the most recently opened threads are kept")
    func oldThreadsAreDropped() throws {
        let services = try makeServices()
        let oldest = services.threadRepository(for: key(1))

        for num in 2...(AppServices.cachedThreadLimit + 1) {
            _ = services.threadRepository(for: key(num))
        }

        #expect(services.threadRepository(for: key(1)) !== oldest)
    }

    @Test("a thread kept in use is not the one dropped")
    func recentlyUsedThreadsSurvive() throws {
        let services = try makeServices()
        let kept = services.threadRepository(for: key(1))

        for num in 2...(AppServices.cachedThreadLimit + 1) {
            _ = services.threadRepository(for: key(num))
            // Asking for it again is what makes it recently used.
            _ = services.threadRepository(for: key(1))
        }

        #expect(services.threadRepository(for: key(1)) === kept)
    }

    @Test("releasing memory keeps the threads the reader can still get back to")
    func releaseKeepsOpenThreads() throws {
        let services = try makeServices()
        let open = services.threadRepository(for: key(1))
        let closed = services.threadRepository(for: key(2))

        services.releaseMemory(keeping: [key(1)])

        #expect(services.threadRepository(for: key(1)) === open)
        #expect(services.threadRepository(for: key(2)) !== closed)
    }
}
