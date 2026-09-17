import Foundation
import SwiftData

/// Remembers which posts were made from this device.
///
/// Keyed by `ThreadKey` and `BoardRef` rather than by loose strings, so the
/// imageboard travels with the board and a post number cannot be looked up
/// against the wrong site. Post numbers are board-wide on both sites, which is
/// why ownership is stored per board rather than per thread.
@ModelActor
public actor OwnPostsRepository {
    public func record(_ key: ThreadKey, postNum: Int) throws {
        guard try stored(on: key.boardRef, postNum: postNum) == nil else { return }
        modelContext.insert(OwnPost(key: key, postNum: postNum))
        try modelContext.save()
    }

    /// Post numbers the reader wrote in one thread.
    public func postNums(in key: ThreadKey) throws -> Set<Int> {
        let site = key.site.rawValue
        let board = key.board
        let threadNum = key.threadNum
        let descriptor = FetchDescriptor<OwnPost>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.postNum))
    }

    /// Lets the reader mark a post as theirs by hand, or unmark it.
    public func setOwned(_ owned: Bool, in key: ThreadKey, postNum: Int) throws {
        if owned {
            try record(key, postNum: postNum)
        } else if let existing = try stored(on: key.boardRef, postNum: postNum) {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    public func isOwned(on board: BoardRef, postNum: Int) throws -> Bool {
        try stored(on: board, postNum: postNum) != nil
    }

    private func stored(on board: BoardRef, postNum: Int) throws -> OwnPost? {
        let site = board.site.rawValue
        let code = board.code
        var descriptor = FetchDescriptor<OwnPost>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == code && $0.postNum == postNum
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
