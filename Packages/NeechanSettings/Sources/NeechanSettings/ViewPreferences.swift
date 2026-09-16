import Foundation

/// How the thread list is laid out.
public enum ThreadsViewMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// One compact line per thread.
    case list
    /// A card with the opening post's text and thumbnail.
    case cards
    /// A thumbnail-led grid.
    case grid

    public var id: String { rawValue }

    public var isGrid: Bool { self == .grid }
}

/// How the catalog is ordered. Only the catalog can be reordered; the paged
/// index is always in the server's bump order.
public enum CatalogSort: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The server's own order: most recently bumped first.
    case bumpOrder
    /// Newest thread first.
    case creationDate
    /// Most replies first.
    case replyCount

    public var id: String { rawValue }
}

/// When the "new posts" divider is shown in a thread.
public enum UnreadMarkerMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Posts are marked read as they scroll past.
    case automatic
    /// Posts stay unread until the reader says otherwise.
    case manual
    /// No divider at all.
    case never

    public var id: String { rawValue }
}

/// How the favourites list is ordered.
public enum FavoritesOrder: String, CaseIterable, Sendable, Codable, Identifiable {
    case newestFirst
    case oldestFirst
    case title
    /// Threads with new posts first, which is what a watcher list is for.
    case unreadFirst

    public var id: String { rawValue }
}

/// When a newly favourited thread starts being watched.
public enum WatcherNotificationSetting: String, CaseIterable, Sendable, Codable, Identifiable {
    /// No notifications at all.
    case off
    /// Only replies to the reader's own posts.
    case repliesOnly
    /// Any new post in a watched thread.
    case allNewPosts

    public var id: String { rawValue }
}

/// When full-size media and thumbnails may be fetched.
public enum MediaLoadPolicy: String, CaseIterable, Sendable, Codable, Identifiable {
    case always
    case wifiOnly
    case never

    public var id: String { rawValue }
}

/// What to do when a download would overwrite a file already on disk.
///
/// Lives here rather than beside `ConflictResolver` so it can be stored as a
/// preference; the resolver reads it back.
public enum DownloadConflictAction: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Ask the reader each time.
    case ask
    case replace
    /// Keep both, by giving the new file a numbered suffix.
    case keepBoth
    case skip

    public var id: String { rawValue }
}

/// Whether the app follows the system appearance or pins one.
public enum AppearanceMode: String, CaseIterable, Sendable, Codable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

/// How much of a thread is kept in memory as it grows.
public enum EndlessThreadMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Load only what the reader scrolls to.
    case `default`
    /// Load every post the server still holds.
    case fullLoad
    /// Load everything, then drop the oldest posts once past the bump limit.
    case fullLoadWithCleanup

    public var id: String { rawValue }
}
