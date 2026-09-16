import Foundation
import SwiftData

/// Remembers which posts were made from this device.
@ModelActor
public actor OwnPostsRepository {
    public func record(board: String, threadNum: Int, postNum: Int) throws {
        guard try stored(board: board, postNum: postNum) == nil else { return }
        modelContext.insert(OwnPost(board: board, threadNum: threadNum, postNum: postNum))
        try modelContext.save()
    }

    /// Post numbers the reader wrote in one thread.
    public func postNums(board: String, threadNum: Int) throws -> Set<Int> {
        let descriptor = FetchDescriptor<OwnPost>(
            predicate: #Predicate { $0.board == board && $0.threadNum == threadNum }
        )
        return Set(try modelContext.fetch(descriptor).map(\.postNum))
    }

    /// Lets the reader mark a post as theirs by hand, or unmark it.
    public func setOwned(_ owned: Bool, board: String, threadNum: Int, postNum: Int) throws {
        if owned {
            try record(board: board, threadNum: threadNum, postNum: postNum)
        } else if let existing = try stored(board: board, postNum: postNum) {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    public func isOwned(board: String, postNum: Int) throws -> Bool {
        try stored(board: board, postNum: postNum) != nil
    }

    private func stored(board: String, postNum: Int) throws -> OwnPost? {
        var descriptor = FetchDescriptor<OwnPost>(
            predicate: #Predicate { $0.board == board && $0.postNum == postNum }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
