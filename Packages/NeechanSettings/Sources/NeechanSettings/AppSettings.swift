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

    /// Whether this is the build meant for the App Store.
    ///
    /// It changes two things and only two: boards for adults start hidden
    /// rather than shown, and posting is off and cannot be turned on.
    @ObservationIgnored private let isAppStoreBuild: Bool

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

    // MARK: Preferences read while drawing
    //
    // These nine are stored rather than computed, and they are the only ones
    // that are. Everything else shares `revision`, which means a write to any
    // preference is indistinguishable from a write to every other: the post
    // cells and thumbnails that read these were being rebuilt whenever an
    // unrelated setting moved, and the counters below moved on every thread
    // opened and every trip to the background. Storing them also takes the
    // `UserDefaults` lookup out of the render path, which is the other half of
    // what made these expensive to read.

    private var storedImageboard: Imageboard
    private var storedDomain: DvachDomain
    private var storedTextScale: Double
    private var storedThumbnailScale: Double
    private var storedCollapsePostLineLimit: Int
    private var storedNSFWMode: Bool
    private var storedMediaLoadPolicy: MediaLoadPolicy
    private var storedAutoRefreshIntervalSeconds: Int
    private var storedShowsHiddenThreads: Bool

    /// Bumped by the usage counters alone.
    ///
    /// Only the About screen reads them, and they are written while the reader
    /// is reading: through the shared `revision` every thread opened redrew
    /// every post on screen.
    private var statisticsRevision = 0

    /// - Parameter isAppStoreBuild: read from the bundle by default, and
    ///   injectable only so a test can ask what that build does without being
    ///   that build.
    public init(
        defaults: UserDefaults = .standard,
        isAppStoreBuild: Bool = BuildVariant.isAppStore
    ) {
        self.storedDefaults = defaults
        self.isAppStoreBuild = isAppStoreBuild
        self.storedImageboard = Self.readImageboard(defaults)
        self.storedDomain = Self.readDomain(defaults)
        self.storedTextScale = Self.clampScale(
            Self.readDouble(defaults, Key.textScale, default: 1)
        )
        self.storedThumbnailScale = Self.clampScale(
            Self.readDouble(defaults, Key.thumbnailScale, default: Self.defaultThumbnailScale)
        )
        self.storedCollapsePostLineLimit = Self.readInt(
            defaults, Key.collapseLines, default: 12
        )
        Self.migrateSafeForWork(defaults)
        self.storedNSFWMode = Self.readBool(defaults, Key.nsfwMode, default: false)
        self.storedMediaLoadPolicy = defaults.string(forKey: Key.mediaLoadPolicy)
            .flatMap(MediaLoadPolicy.init(rawValue:)) ?? .always
        self.storedAutoRefreshIntervalSeconds = Self.readInt(
            defaults, Key.autoRefresh, default: 0
        )
        self.storedShowsHiddenThreads = Self.readBool(
            defaults, Key.showsHiddenThreads, default: true
        )
    }

    /// Writes a preference and tells anyone observing it.
    private func write(_ value: Any?, forKey key: String) {
        revision &+= 1
        storedDefaults.set(value, forKey: key)
    }

    /// Writes a usage counter, which nothing on a reading screen observes.
    private func writeStatistic(_ value: Any?, forKey key: String) {
        statisticsRevision &+= 1
        storedDefaults.set(value, forKey: key)
    }

    // Read as the stored type when there is one and coerced when there is not.
    // A value pinned by a launch argument arrives as a string, and an `as?`
    // cast drops it on the floor, so a test pinning a preference silently got
    // the default instead.

    private static func readBool(
        _ defaults: UserDefaults, _ key: String, default fallback: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func readInt(
        _ defaults: UserDefaults, _ key: String, default fallback: Int
    ) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private static func readDouble(
        _ defaults: UserDefaults, _ key: String, default fallback: Double
    ) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private static func readImageboard(_ defaults: UserDefaults) -> Imageboard {
        defaults.string(forKey: Key.imageboard)
            .flatMap(Imageboard.init(rawValue:)) ?? .default
    }

    private static func readDomain(_ defaults: UserDefaults) -> DvachDomain {
        defaults.string(forKey: Key.domain)
            .flatMap(DvachDomain.init(rawValue:)) ?? .default
    }

    /// A preference that is on unless something says otherwise.
    ///
    /// Not `object(forKey:) as? Bool`: a value pinned by a launch argument
    /// arrives as a string, which that cast drops on the floor, so a test
    /// pinning a preference silently got the default instead.
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// Lets the reader delete their own posts on a site that asks for one.
    ///
    /// 4chan's reply form generates a password per browser and sends it with
    /// every post; deleting a post later means presenting the same one. Kept
    /// per install, made once and never shown.
    public var postDeletionPassword: String {
        if let stored = defaults.string(forKey: Key.postDeletionPassword), !stored.isEmpty {
            return stored
        }
        let generated = Self.randomFileName()
        write(generated, forKey: Key.postDeletionPassword)
        return generated
    }

    /// The imageboard all requests go to.
    ///
    /// Stored rather than computed, like `domain`: it is read on the way to
    /// every repository call a screen makes, so routing it through `revision`
    /// would redraw every board row and post cell whenever any unrelated
    /// preference moved.
    public var imageboard: Imageboard {
        get { storedImageboard }
        set {
            guard newValue != storedImageboard else { return }
            storedImageboard = newValue
            storedDefaults.set(newValue.rawValue, forKey: Key.imageboard)
        }
    }

    /// Which imageboard, and which of its mirrors — what the client needs to
    /// build a URL.
    public var siteSelection: SiteSelection {
        SiteSelection(site: imageboard, mirror: domain)
    }

    /// The 2ch mirror all requests go to. Meaningless off 2ch.
    public var domain: DvachDomain {
        get { storedDomain }
        set {
            guard newValue != storedDomain else { return }
            storedDomain = newValue
            storedDefaults.set(newValue.rawValue, forKey: Key.domain)
        }
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

    /// How the posts inside a thread are drawn.
    ///
    /// The continuous list is the default; cards are what the app drew before
    /// it had a choice, kept for readers who preferred them.
    public var postsViewMode: PostsViewMode {
        get {
            defaults.string(forKey: Key.postsViewMode)
                .flatMap(PostsViewMode.init(rawValue:)) ?? .list
        }
        set { write(newValue.rawValue, forKey: Key.postsViewMode) }
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
        get { Self.readInt(defaults, Key.watcherInterval, default: 60) }
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
        get { storedShowsHiddenThreads }
        set {
            guard newValue != storedShowsHiddenThreads else { return }
            storedShowsHiddenThreads = newValue
            storedDefaults.set(newValue, forKey: Key.showsHiddenThreads)
        }
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
        get { storedTextScale }
        set {
            let clamped = Self.clampScale(newValue)
            guard clamped != storedTextScale else { return }
            storedTextScale = clamped
            storedDefaults.set(clamped, forKey: Key.textScale)
        }
    }

    /// How large attachment thumbnails are unless the reader says otherwise.
    ///
    /// A little under full size: the thumbnails the site serves are bigger than
    /// a post needs, and at full size they crowd out the text that was the
    /// reason for opening the thread.
    public static let defaultThumbnailScale = 0.8

    /// Multiplies attachment thumbnails.
    public var thumbnailScale: Double {
        get { storedThumbnailScale }
        set {
            let clamped = Self.clampScale(newValue)
            guard clamped != storedThumbnailScale else { return }
            storedThumbnailScale = clamped
            storedDefaults.set(clamped, forKey: Key.thumbnailScale)
        }
    }

    /// How many lines a post shows before it offers to expand.
    public var collapsePostLineLimit: Int {
        get { storedCollapsePostLineLimit }
        set {
            let clamped = max(3, min(60, newValue))
            guard clamped != storedCollapsePostLineLimit else { return }
            storedCollapsePostLineLimit = clamped
            storedDefaults.set(clamped, forKey: Key.collapseLines)
        }
    }

    /// Whether material not safe for work is shown as it comes.
    ///
    /// Off blurs every thumbnail until it is tapped, which is what a reader on
    /// a train wants. The inverse of the `interface.safeForWork` preference
    /// this replaces — see `migrateSafeForWork`.
    public var nsfwMode: Bool {
        get { storedNSFWMode }
        set {
            guard newValue != storedNSFWMode else { return }
            storedNSFWMode = newValue
            storedDefaults.set(newValue, forKey: Key.nsfwMode)
        }
    }

    /// Whether boards meant for adults are shown at all.
    ///
    /// Computed rather than stored although the board list reads it, because
    /// sharing `revision` is the point: turning this off has to make the board
    /// list, favourites, history, saved threads and every open route all
    /// re-evaluate at once, and a stored property gives observation without
    /// that blanket invalidation.
    /// The App Store build starts with this off. It is still a preference
    /// there: a reader who turns it on gets the same 21+ prompt and it stays
    /// on. Only where it begins is different.
    public var allowsMatureBoards: Bool {
        get { bool(Key.allowsMature, default: !isAppStoreBuild) }
        set { write(newValue, forKey: Key.allowsMature) }
    }

    /// Whether the reader can post at all, on either imageboard.
    ///
    /// Not a preference, and deliberately not stored: the App Store build
    /// cannot post and every other build always can. A constant is the only
    /// thing that can fix it off, because `bool(_:default:)` honours the
    /// argument domain so a launch argument could otherwise pin it back on,
    /// and neither a changed default nor `register(defaults:)` would win.
    ///
    /// One consequence worth knowing: this does not read `defaults` and so
    /// does not observe `revision`. That is right — a constant has nothing to
    /// announce — but it is the one thing here that does not.
    public var allowsPosting: Bool { !isAppStoreBuild }

    /// Whether this is the build meant for the App Store.
    ///
    /// Read from here rather than from `BuildVariant.isAppStore` directly so
    /// that a test can construct the other build: in a test bundle
    /// `Bundle.main` is the runner, which carries no such key, and the flag is
    /// injected into `init` for exactly this reason.
    public var isAppStore: Bool { isAppStoreBuild }

    /// Whether the reader has accepted the terms.
    ///
    /// Only the App Store build asks, and it asks before it shows anything
    /// else. A preference rather than a record — nothing else knows about it —
    /// so it lives here by this file's own rule.
    public var hasAgreedToTerms: Bool {
        get { bool(Key.agreedToTerms, default: false) }
        set { write(newValue, forKey: Key.agreedToTerms) }
    }

    /// Carries a reader's `interface.safeForWork` into `nsfwMode`, once.
    ///
    /// The two mean opposite things, so the value has to be inverted rather
    /// than copied, and the *defaults* disagree too: `safeForWork` defaulted to
    /// off, which meant no blur, while `nsfwMode` defaults to off, which means
    /// blur. So a reader who never touched the old toggle cannot be served by
    /// either the stored value (there is none) or the new default (it reverses
    /// their experience).
    ///
    /// Hence the middle case: if the app has been used before, keep what they
    /// had. `recordThreadOpened()` is called for every thread opened and
    /// `secondsInApp` accumulates on every trip to the background, so anyone
    /// who has actually read anything has one of them. Deliberately a narrow
    /// probe of two keys rather than a survey of the whole domain — it is a
    /// judgement about one preference, and it should be readable as one.
    private static func migrateSafeForWork(_ defaults: UserDefaults) {
        guard defaults.object(forKey: Key.nsfwMode) == nil else { return }

        if defaults.object(forKey: LegacyKey.safeForWork) != nil {
            defaults.set(!defaults.bool(forKey: LegacyKey.safeForWork), forKey: Key.nsfwMode)
        } else if defaults.object(forKey: Key.threadsOpened) != nil
            || defaults.object(forKey: Key.secondsInApp) != nil {
            defaults.set(true, forKey: Key.nsfwMode)
        }
        // Anything else is a fresh install, and the new default is right for it.

        defaults.removeObject(forKey: LegacyKey.safeForWork)
    }

    // MARK: General

    /// Whether opened threads are recorded in History.
    public var remembersHistory: Bool {
        get { bool(Key.remembersHistory, default: true) }
        set { write(newValue, forKey: Key.remembersHistory) }
    }

    /// The app icon the reader picked, or nil for the one it ships with.
    ///
    /// Stored rather than read back from the system so the settings screen can
    /// draw the choice before the first frame; what is actually on the home
    /// screen is the system's to report, and the two are kept in step when the
    /// choice is applied.
    public var appIconName: String? {
        get { defaults.string(forKey: Key.appIcon) }
        set { write(newValue, forKey: Key.appIcon) }
    }

    /// Whether the app asks who is holding the device before showing anything.
    ///
    /// Off unless the reader asks for it. What the check accepts is the
    /// device's own business: a face, a fingerprint or the passcode, whichever
    /// the device has.
    public var locksApp: Bool {
        get { bool(Key.appLock, default: false) }
        set { write(newValue, forKey: Key.appLock) }
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
        get { storedAutoRefreshIntervalSeconds }
        set {
            let clamped = newValue <= 0 ? 0 : max(15, newValue)
            guard clamped != storedAutoRefreshIntervalSeconds else { return }
            storedAutoRefreshIntervalSeconds = clamped
            storedDefaults.set(clamped, forKey: Key.autoRefresh)
        }
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
        get { storedMediaLoadPolicy }
        set {
            guard newValue != storedMediaLoadPolicy else { return }
            storedMediaLoadPolicy = newValue
            storedDefaults.set(newValue.rawValue, forKey: Key.mediaLoadPolicy)
        }
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

    /// The sizes the media cache may be set to, in megabytes.
    ///
    /// Four, far apart, because the choice is "roughly how much of this phone am
    /// I willing to give a board" and nobody wants to pick between 512 MB and
    /// 1 GB. Video is what fills this: one clip can be 60 MB, so the smallest
    /// here still holds a evening's worth.
    public static let cacheLimitChoicesMegabytes = [5 * 1024, 10 * 1024, 20 * 1024, 50 * 1024]

    /// Ceiling for the on-disk media cache, in megabytes.
    ///
    /// Always one of `cacheLimitChoicesMegabytes`, on the way in and on the way
    /// out, so what settings shows and what the cache enforces cannot disagree.
    /// A value stored by an older version is read as the nearest of them.
    public var mediaCacheLimitMegabytes: Int {
        get {
            Self.nearestCacheLimit(
                Self.readInt(
                    defaults, Key.cacheLimit, default: Self.cacheLimitChoicesMegabytes[0]
                )
            )
        }
        set { write(Self.nearestCacheLimit(newValue), forKey: Key.cacheLimit) }
    }

    /// How long cached media may go unused before it is dropped, in days.
    ///
    /// Zero is forever, and is last on purpose: the slider runs from the
    /// shortest keep to no limit at all.
    public static let cacheAgeChoicesDays = [1, 7, 30, 0]

    /// How long media is kept unless the reader says otherwise.
    ///
    /// A month is long enough that a thread followed over several weeks still
    /// opens from disk, and short enough that a phone is not carrying last
    /// spring's webms around. Forever is one drag away for anyone who wants it.
    public static let defaultCacheAgeDays = 30

    /// Drop cached media untouched for this many days, or zero to keep it.
    ///
    /// Measured from when a file was last used rather than from when it
    /// arrived, so a clip watched again this morning is not thrown away for
    /// having been fetched last month.
    public var mediaCacheMaxAgeDays: Int {
        get {
            let stored = Self.readInt(
                defaults, Key.cacheMaxAge, default: Self.defaultCacheAgeDays
            )
            return Self.cacheAgeChoicesDays.contains(stored)
                ? stored
                : Self.defaultCacheAgeDays
        }
        set {
            write(
                Self.cacheAgeChoicesDays.contains(newValue)
                    ? newValue
                    : Self.defaultCacheAgeDays,
                forKey: Key.cacheMaxAge
            )
        }
    }

    /// The allowed size closest to what was asked for.
    public static func nearestCacheLimit(_ megabytes: Int) -> Int {
        cacheLimitChoicesMegabytes.min {
            abs($0 - megabytes) < abs($1 - megabytes)
        } ?? cacheLimitChoicesMegabytes[0]
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
        _ = statisticsRevision
        return UsageStatistics(
            secondsInApp: storedDefaults.double(forKey: Key.secondsInApp),
            postsSent: storedDefaults.integer(forKey: Key.postsSent),
            threadsOpened: storedDefaults.integer(forKey: Key.threadsOpened)
        )
    }

    /// Adds a stretch of foreground time.
    ///
    /// - Parameter seconds: ignored when negative or implausibly long, which is
    ///   what a clock change or a session the system never told us ended looks
    ///   like.
    public func addTimeInApp(seconds: TimeInterval) {
        guard seconds > 0, seconds < 60 * 60 * 8 else { return }
        writeStatistic(statistics.secondsInApp + seconds, forKey: Key.secondsInApp)
    }

    public func recordPostSent() {
        writeStatistic(statistics.postsSent + 1, forKey: Key.postsSent)
    }

    public func recordThreadOpened() {
        writeStatistic(statistics.threadsOpened + 1, forKey: Key.threadsOpened)
    }

    public func resetStatistics() {
        writeStatistic(0.0, forKey: Key.secondsInApp)
        writeStatistic(0, forKey: Key.postsSent)
        writeStatistic(0, forKey: Key.threadsOpened)
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
        SettingsSnapshot(imageboard: imageboard, domain: domain, defaultBoard: defaultBoard)
    }

    private enum Key {
        static let imageboard = "imageboard"
        static let postDeletionPassword = "posting.deletionPassword"
        static let domain = "domain"
        static let defaultBoard = "defaultBoard"
        static let uniqueHash = "attachment.uniqueHash"
        static let stripMetadata = "attachment.stripMetadata"
        static let removeFileName = "attachment.removeFileName"
        static let postsViewMode = "postsViewMode"
        static let unreadMarkerMode = "unreadMarkerMode"
        static let watcherInterval = "watcher.interval"
        static let watcherNotifications = "watcher.notifications"
        static let showsHiddenThreads = "showsHiddenThreads"
        static let appearance = "interface.appearance"
        static let themeID = "interface.theme"
        static let textScale = "interface.textScale"
        static let thumbnailScale = "interface.thumbnailScale"
        static let collapseLines = "interface.collapseLines"
        static let nsfwMode = "restrictions.nsfwMode"
        static let allowsMature = "restrictions.allowsMature"
        static let remembersHistory = "general.remembersHistory"
        static let internalBrowser = "general.internalBrowser"
        static let appLock = "general.appLock"
        static let appIcon = "interface.appIcon"
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
        static let cacheMaxAge = "media.cacheMaxAge"
        static let boardViewModes = "board.viewModes"
        static let lastViewMode = "board.lastViewMode"
        static let language = "general.language"
        static let agreedToTerms = "general.agreedToTerms"
        static let secondsInApp = "stats.secondsInApp"
        static let postsSent = "stats.postsSent"
        static let threadsOpened = "stats.threadsOpened"
    }

    /// Keys no longer written, kept only so their values can be migrated.
    private enum LegacyKey {
        /// Replaced by `Key.nsfwMode`, which means the opposite.
        static let safeForWork = "interface.safeForWork"
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
    public var imageboard: Imageboard
    public var domain: DvachDomain
    public var defaultBoard: String?

    public init(
        imageboard: Imageboard = .default,
        domain: DvachDomain = .default,
        defaultBoard: String? = nil
    ) {
        self.imageboard = imageboard
        self.domain = domain
        self.defaultBoard = defaultBoard
    }

    /// What the client needs to build a URL.
    public var siteSelection: SiteSelection {
        SiteSelection(site: imageboard, mirror: domain)
    }
}
