import Foundation
import NeechanAPI
import Observation

/// User preferences, backed by `UserDefaults`.
///
/// Grows milestone by milestone. Anything that is a *record* rather than a
/// preference (favorites, history, drafts) lives in SwiftData instead.
@MainActor
@Observable
public final class AppSettings {
    public static let suiteName = "group.com.lain.neechan"

    @ObservationIgnored private let storedDefaults: UserDefaults

    /// Bumped by every write.
    ///
    /// Observation tracks stored properties, and every preference below is a
    /// computed property over `UserDefaults`, which it cannot see into. Reading
    /// this on the way to the defaults makes each preference observable, and
    /// bumping it on a write is what makes a change reach the views. Without it
    /// a setting appears to do nothing until the screen is rebuilt for some
    /// unrelated reason.
    private var revision = 0

    /// The defaults, touched through `revision` so the read is observed.
    private var defaults: UserDefaults {
        _ = revision
        return storedDefaults
    }

    public init(defaults: UserDefaults = .standard) {
        self.storedDefaults = defaults
    }

    /// Writes a preference and tells anyone observing it.
    private func write(_ value: Any?, forKey key: String) {
        revision &+= 1
        storedDefaults.set(value, forKey: key)
    }

    /// A preference that is on unless something says otherwise.
    ///
    /// Not `object(forKey:) as? Bool`: a value pinned by a launch argument
    /// arrives as a string, which that cast drops on the floor, so a test
    /// pinning a preference silently got the default instead.
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// The 2ch mirror all requests go to.
    public var domain: DvachDomain {
        get {
            defaults.string(forKey: Key.domain)
                .flatMap(DvachDomain.init(rawValue:)) ?? .default
        }
        set { write(newValue.rawValue, forKey: Key.domain) }
    }

    /// Board opened when the app launches, if any.
    public var defaultBoard: String? {
        get { defaults.string(forKey: Key.defaultBoard) }
        set { write(newValue, forKey: Key.defaultBoard) }
    }

    /// Per-file defaults applied to anything the reader attaches.
    ///
    /// Uploading the same image twice is refused by the site, and photos carry
    /// location data, so both are handled by default rather than left as traps.
    public var appendsUniqueHashByDefault: Bool {
        get { bool(Key.uniqueHash, default: true) }
        set { write(newValue, forKey: Key.uniqueHash) }
    }

    public var stripsMetadataByDefault: Bool {
        get { bool(Key.stripMetadata, default: true) }
        set { write(newValue, forKey: Key.stripMetadata) }
    }

    /// Whether an attached file is renamed before it is sent.
    ///
    /// On by default: a camera roll name such as `IMG_4471` says which device
    /// took it and roughly when, which is not something to post by accident.
    public var removesFileNamesByDefault: Bool {
        get { bool(Key.removeFileName, default: true) }
        set { write(newValue, forKey: Key.removeFileName) }
    }

    /// A fresh random name for one attachment, without its extension.
    ///
    /// Random rather than a fixed word so two files attached to the same post
    /// do not collide, and so nothing about the original survives.
    public nonisolated static func randomFileName() -> String {
        (0..<16).map { _ in "0123456789abcdef".randomElement() ?? "0" }.map(String.init).joined()
    }

    /// When the "new posts" divider is shown in a thread.
    public var unreadMarkerMode: UnreadMarkerMode {
        get {
            defaults.string(forKey: Key.unreadMarkerMode)
                .flatMap(UnreadMarkerMode.init(rawValue:)) ?? .automatic
        }
        set { write(newValue.rawValue, forKey: Key.unreadMarkerMode) }
    }

    /// How often the watcher polls while the app is in front, in seconds.
    public var watcherIntervalSeconds: Int {
        get { defaults.object(forKey: Key.watcherInterval) as? Int ?? 60 }
        set { write(max(15, newValue), forKey: Key.watcherInterval) }
    }

    /// Which new posts are worth a notification.
    public var watcherNotifications: WatcherNotificationSetting {
        get {
            defaults.string(forKey: Key.watcherNotifications)
                .flatMap(WatcherNotificationSetting.init(rawValue:)) ?? .repliesOnly
        }
        set { write(newValue.rawValue, forKey: Key.watcherNotifications) }
    }

    /// Whether a hidden thread collapses to a dim one-line stub or goes from
    /// the board altogether.
    ///
    /// Collapsing by default: hiding a thread is usually about not wanting to
    /// look at it rather than about never seeing it again, and a row that
    /// vanishes leaves no way back to it from the board.
    public var showsHiddenThreads: Bool {
        get { bool(Key.showsHiddenThreads, default: true) }
        set { write(newValue, forKey: Key.showsHiddenThreads) }
    }


    // MARK: Interface

    /// Whether the app follows the system appearance or pins one.
    public var appearance: AppearanceMode {
        get {
            defaults.string(forKey: Key.appearance)
                .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        }
        set { write(newValue.rawValue, forKey: Key.appearance) }
    }

    /// The identifier of the selected theme, or nil for the built-in look.
    public var themeID: String? {
        get { defaults.string(forKey: Key.themeID) }
        set { write(newValue, forKey: Key.themeID) }
    }

    /// Multiplies post text on top of Dynamic Type.
    public var textScale: Double {
        get { Self.clampScale(defaults.object(forKey: Key.textScale) as? Double ?? 1) }
        set { write(Self.clampScale(newValue), forKey: Key.textScale) }
    }

    /// Multiplies attachment thumbnails.
    public var thumbnailScale: Double {
        get { Self.clampScale(defaults.object(forKey: Key.thumbnailScale) as? Double ?? 1) }
        set { write(Self.clampScale(newValue), forKey: Key.thumbnailScale) }
    }

    /// How many lines a post shows before it offers to expand.
    public var collapsePostLineLimit: Int {
        get { defaults.object(forKey: Key.collapseLines) as? Int ?? 12 }
        set { write(max(3, min(60, newValue)), forKey: Key.collapseLines) }
    }

    /// Hides attachments and blurs thumbnails, for reading in public.
    public var safeForWork: Bool {
        get { defaults.bool(forKey: Key.safeForWork) }
        set { write(newValue, forKey: Key.safeForWork) }
    }

    // MARK: General

    /// Whether opened threads are recorded in History.
    public var remembersHistory: Bool {
        get { bool(Key.remembersHistory, default: true) }
        set { write(newValue, forKey: Key.remembersHistory) }
    }

    /// Whether links open in the app or in the system browser.
    public var usesInternalBrowser: Bool {
        get { bool(Key.internalBrowser, default: true) }
        set { write(newValue, forKey: Key.internalBrowser) }
    }

    // MARK: Forum

    /// Whether a board opens as the catalog rather than page by page.
    ///
    /// On by default: the catalog is one request for the whole board and is how
    /// most readers use it, while paging costs a request per page.
    public var catalogByDefault: Bool {
        get { bool(Key.catalogByDefault, default: true) }
        set { write(newValue, forKey: Key.catalogByDefault) }
    }

    // MARK: Contents

    /// How often an open thread refreshes itself, or 0 for never.
    public var autoRefreshIntervalSeconds: Int {
        get { defaults.object(forKey: Key.autoRefresh) as? Int ?? 0 }
        set { write(newValue <= 0 ? 0 : max(15, newValue), forKey: Key.autoRefresh) }
    }

    /// How much of a long thread is loaded at once.
    public var endlessThreadMode: EndlessThreadMode {
        get {
            defaults.string(forKey: Key.endlessMode)
                .flatMap(EndlessThreadMode.init(rawValue:)) ?? .default
        }
        set { write(newValue.rawValue, forKey: Key.endlessMode) }
    }

    /// The order of the Favorites list.
    public var favoritesOrder: FavoritesOrder {
        get {
            defaults.string(forKey: Key.favoritesOrder)
                .flatMap(FavoritesOrder.init(rawValue:)) ?? .unreadFirst
        }
        set { write(newValue.rawValue, forKey: Key.favoritesOrder) }
    }

    /// Whether replying to a thread favourites it.
    public var favoritesOnReply: Bool {
        get { bool(Key.favoriteOnReply, default: true) }
        set { write(newValue, forKey: Key.favoriteOnReply) }
    }

    /// Whether a newly favourited thread starts watched.
    public var watchesNewFavorites: Bool {
        get { bool(Key.watchNewFavorites, default: true) }
        set { write(newValue, forKey: Key.watchNewFavorites) }
    }

    /// Whether the watcher polls on cellular as well as Wi-Fi.
    public var watcherWiFiOnly: Bool {
        get { defaults.bool(forKey: Key.watcherWiFiOnly) }
        set { write(newValue, forKey: Key.watcherWiFiOnly) }
    }

    // MARK: Media

    /// When thumbnails and media may be fetched.
    public var mediaLoadPolicy: MediaLoadPolicy {
        get {
            defaults.string(forKey: Key.mediaLoadPolicy)
                .flatMap(MediaLoadPolicy.init(rawValue:)) ?? .always
        }
        set { write(newValue.rawValue, forKey: Key.mediaLoadPolicy) }
    }

    /// Whether a video restarts when it ends.
    public var videoLoops: Bool {
        get { defaults.bool(forKey: Key.videoLoops) }
        set { write(newValue, forKey: Key.videoLoops) }
    }

    /// Whether a video starts by itself when opened.
    public var videoAutoplay: Bool {
        get { bool(Key.videoAutoplay, default: true) }
        set { write(newValue, forKey: Key.videoAutoplay) }
    }

    /// What a download does when the name is taken.
    public var downloadConflictAction: DownloadConflictAction {
        get {
            defaults.string(forKey: Key.conflictAction)
                .flatMap(DownloadConflictAction.init(rawValue:)) ?? .keepBoth
        }
        set { write(newValue.rawValue, forKey: Key.conflictAction) }
    }

    /// Folder layout under the download destination.
    public var downloadSubdirectoryPattern: String {
        get { defaults.string(forKey: Key.subdirectoryPattern) ?? "<board>/<thread>" }
        set { write(newValue, forKey: Key.subdirectoryPattern) }
    }

    /// Whether downloads go to Photos instead of Files.
    /// Whether a WebM is converted to MP4 when it is saved.
    ///
    /// On by default: Photos refuses a WebM outright, and nothing outside this
    /// app plays one. It costs a re-encode, which is why it can be turned off.
    public var convertsWebMOnSave: Bool {
        get { bool(Key.convertWebM, default: true) }
        set { write(newValue, forKey: Key.convertWebM) }
    }

    public var savesToPhotos: Bool {
        get { bool(Key.savesToPhotos, default: true) }
        set { write(newValue, forKey: Key.savesToPhotos) }
    }

    /// Bookmark of the folder downloads are written to, when one was picked.
    public var downloadFolderBookmark: Data? {
        get { defaults.data(forKey: Key.downloadBookmark) }
        set { write(newValue, forKey: Key.downloadBookmark) }
    }

    /// Ceiling for the on-disk media cache, in megabytes.
    public var mediaCacheLimitMegabytes: Int {
        get { defaults.object(forKey: Key.cacheLimit) as? Int ?? 512 }
        set { write(max(32, newValue), forKey: Key.cacheLimit) }
    }

    /// Clamps a scale to what the layout can absorb without breaking.
    private static func clampScale(_ value: Double) -> Double {
        min(2, max(0.75, value))
    }

    // MARK: Language

    /// The language the app draws itself in, or nil to follow the system.
    ///
    /// Applied as the SwiftUI locale rather than by rewriting `AppleLanguages`,
    /// so a change takes effect immediately instead of on the next launch.
    public var languageCode: String? {
        get {
            let stored = defaults.string(forKey: Key.language)
            // "system" spells "follow the system" explicitly, which is what a
            // launch argument can pass; an empty string means the same.
            guard let stored, stored != "system", !stored.isEmpty else { return nil }
            return stored
        }
        set { write(newValue, forKey: Key.language) }
    }

    // MARK: Statistics

    /// What the reader has done with the app, for the About screen.
    public var statistics: UsageStatistics {
        UsageStatistics(
            secondsInApp: defaults.double(forKey: Key.secondsInApp),
            postsSent: defaults.integer(forKey: Key.postsSent),
            threadsOpened: defaults.integer(forKey: Key.threadsOpened)
        )
    }

    /// Adds a stretch of foreground time.
    ///
    /// - Parameter seconds: ignored when negative or implausibly long, which is
    ///   what a clock change or a session the system never told us ended looks
    ///   like.
    public func addTimeInApp(seconds: TimeInterval) {
        guard seconds > 0, seconds < 60 * 60 * 8 else { return }
        write(statistics.secondsInApp + seconds, forKey: Key.secondsInApp)
    }

    public func recordPostSent() {
        write(statistics.postsSent + 1, forKey: Key.postsSent)
    }

    public func recordThreadOpened() {
        write(statistics.threadsOpened + 1, forKey: Key.threadsOpened)
    }

    public func resetStatistics() {
        write(0.0, forKey: Key.secondsInApp)
        write(0, forKey: Key.postsSent)
        write(0, forKey: Key.threadsOpened)
    }

    // MARK: Board layout

    /// How a board's thread list is laid out.
    ///
    /// Kept per board: a board of images wants the grid and a board of text
    /// wants the list, and a reader who set one does not expect the other to
    /// change with it. A board never opened before follows whatever was chosen
    /// most recently, so a new board feels like the app already in use.
    public func threadsViewMode(forBoard board: String) -> ThreadsViewMode {
        let stored = defaults.dictionary(forKey: Key.boardViewModes) as? [String: String]
        if let mode = stored?[board].flatMap(ThreadsViewMode.init(rawValue:)) {
            return mode
        }
        return defaults.string(forKey: Key.lastViewMode)
            .flatMap(ThreadsViewMode.init(rawValue:)) ?? .cards
    }

    public func setThreadsViewMode(_ mode: ThreadsViewMode, forBoard board: String) {
        var stored = (storedDefaults.dictionary(forKey: Key.boardViewModes) as? [String: String]) ?? [:]
        stored[board] = mode.rawValue
        write(stored, forKey: Key.boardViewModes)
        write(mode.rawValue, forKey: Key.lastViewMode)
    }

    /// A `Sendable` copy safe to hand to actors and background work.
    public var snapshot: SettingsSnapshot {
        SettingsSnapshot(domain: domain, defaultBoard: defaultBoard)
    }

    private enum Key {
        static let domain = "domain"
        static let defaultBoard = "defaultBoard"
        static let uniqueHash = "attachment.uniqueHash"
        static let stripMetadata = "attachment.stripMetadata"
        static let removeFileName = "attachment.removeFileName"
        static let unreadMarkerMode = "unreadMarkerMode"
        static let watcherInterval = "watcher.interval"
        static let watcherNotifications = "watcher.notifications"
        static let showsHiddenThreads = "showsHiddenThreads"
        static let appearance = "interface.appearance"
        static let themeID = "interface.theme"
        static let textScale = "interface.textScale"
        static let thumbnailScale = "interface.thumbnailScale"
        static let collapseLines = "interface.collapseLines"
        static let safeForWork = "interface.safeForWork"
        static let remembersHistory = "general.remembersHistory"
        static let internalBrowser = "general.internalBrowser"
        static let catalogByDefault = "forum.catalogByDefault"
        static let autoRefresh = "contents.autoRefresh"
        static let endlessMode = "contents.endlessMode"
        static let favoritesOrder = "contents.favoritesOrder"
        static let favoriteOnReply = "contents.favoriteOnReply"
        static let watchNewFavorites = "contents.watchNewFavorites"
        static let watcherWiFiOnly = "watcher.wifiOnly"
        static let mediaLoadPolicy = "media.loadPolicy"
        static let videoLoops = "media.videoLoops"
        static let videoAutoplay = "media.videoAutoplay"
        static let conflictAction = "media.conflictAction"
        static let subdirectoryPattern = "media.subdirectoryPattern"
        static let convertWebM = "media.convertWebM"
        static let savesToPhotos = "media.savesToPhotos"
        static let downloadBookmark = "media.downloadBookmark"
        static let cacheLimit = "media.cacheLimit"
        static let boardViewModes = "board.viewModes"
        static let lastViewMode = "board.lastViewMode"
        static let language = "general.language"
        static let secondsInApp = "stats.secondsInApp"
        static let postsSent = "stats.postsSent"
        static let threadsOpened = "stats.threadsOpened"
    }
}

/// What the reader has done with the app.
public struct UsageStatistics: Sendable, Equatable {
    public var secondsInApp: TimeInterval
    public var postsSent: Int
    public var threadsOpened: Int

    public init(secondsInApp: TimeInterval = 0, postsSent: Int = 0, threadsOpened: Int = 0) {
        self.secondsInApp = secondsInApp
        self.postsSent = postsSent
        self.threadsOpened = threadsOpened
    }
}

/// An immutable view of the settings, safe to cross isolation boundaries.
public struct SettingsSnapshot: Sendable, Equatable {
    public var domain: DvachDomain
    public var defaultBoard: String?

    public init(domain: DvachDomain = .default, defaultBoard: String? = nil) {
        self.domain = domain
        self.defaultBoard = defaultBoard
    }
}
