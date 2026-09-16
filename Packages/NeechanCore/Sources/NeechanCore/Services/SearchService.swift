import Foundation
import NeechanAPI

/// Server-side post search.
///
/// 2ch searches one board at a time and refuses very short queries, so both are
/// surfaced rather than left to fail as a generic error.
public actor SearchService {
    public enum SearchError: Error, Equatable {
        case queryTooShort(minimum: Int)
        case failed(String)
    }

    /// The site rejects anything shorter with error -23.
    public static let minimumQueryLength = 3

    private let client: DvachClient

    public init(client: DvachClient) {
        self.client = client
    }

    public func search(board: String, text: String) async throws(SearchError) -> [Post] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else {
            throw .queryTooShort(minimum: Self.minimumQueryLength)
        }

        do {
            return try await client.search(board: board, text: trimmed).posts
        } catch {
            if error.code == .fieldTooSmall {
                throw .queryTooShort(minimum: Self.minimumQueryLength)
            }
            throw .failed(error.readableWatcherMessage)
        }
    }
}

/// Threads that have fallen off the board and into its archive.
public actor ArchiveRepository {
    public struct Page: Sendable {
        public let threads: [ArchivedThread]
        public let pageNumbers: [Int]
        public let currentPage: Int

        public var hasNextPage: Bool {
            pageNumbers.contains(currentPage + 1)
        }
    }

    private let client: DvachClient

    public init(client: DvachClient) {
        self.client = client
    }

    public func page(board: String, page: Int = 0) async throws(DvachError) -> Page {
        let response = try await client.archive(board: board, page: page)
        return Page(
            threads: response.threads,
            pageNumbers: response.pages,
            currentPage: page
        )
    }
}
