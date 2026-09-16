import Foundation

/// A history row as a value.
///
/// SwiftData's model objects are tied to the context that fetched them and are
/// not `Sendable`, so repositories hand out these instead and nothing managed
/// ever crosses an isolation boundary.
public struct HistoryItem: Sendable, Hashable, Identifiable {
    public let key: ThreadKey
    public let title: String
    public let visitedAt: Date
    public let thumbnailPath: String?

    public var id: ThreadKey { key }

    public init(key: ThreadKey, title: String, visitedAt: Date, thumbnailPath: String?) {
        self.key = key
        self.title = title
        self.visitedAt = visitedAt
        self.thumbnailPath = thumbnailPath
    }
}
