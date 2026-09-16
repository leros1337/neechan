import Foundation
import Synchronization
import NeechanAPI
import NeechanSettings
import SwiftData

/// Wires the app's collaborators together and hands them to the views.
///
/// Built once at launch. Views reach it through the SwiftUI environment rather
/// than constructing clients of their own, so there is exactly one cookie jar,
/// one board cache and one place where the mirror is read from.
@MainActor
@Observable
public final class AppServices {
    public let settings: AppSettings
    public let client: DvachClient
    public let boards: BoardsRepository
    public let catalog: CatalogRepository
    public let history: HistoryRepository
    public let drafts: DraftRepository
    public let ownPosts: OwnPostsRepository
    public let posting: PostingCoordinator
    public let captchaClient: DvachClient
    public let favorites: FavoritesRepository
    public let hidden: HiddenContentRepository
    public let watchedThreads: WatchedThreadStore
    public let watcher: ThreadWatcher
    public let search: SearchService
    public let archive: ArchiveRepository
    public let savedThreads: SavedThreadsRepository
    public let themes: ThemeRepository
    public let backup: BackupService
    public let cookies: CookieManager
    public let downloader: Downloader
    public let reachability = NetworkReachability()

    /// The gate page waiting to be shown, if the site asked for one.
    ///
    /// Set from whichever request ran into it; the shell watches this and puts
    /// the check in front of the reader once, rather than each screen having to
    /// handle it.
    public var pendingChallengeURL: URL?
    #if canImport(UserNotifications)
    public let notifications: NotificationScheduler
    #endif

    @ObservationIgnored private var threadRepositories: [ThreadKey: ThreadRepository] = [:]
    /// Thread keys in the order they were last asked for, oldest first.
    @ObservationIgnored private var threadOrder: [ThreadKey] = []
    /// Bridges the main-actor settings to the client, which reads the domain
    /// from its own executor.
    @ObservationIgnored private let domainHolder: DomainHolder
    @ObservationIgnored private let challenges: ChallengeRelay

    public init(
        settings: AppSettings,
        modelContainer: ModelContainer,
        transport: (any HTTPTransport)? = nil
    ) {
        self.settings = settings

        // The mirror is read on every request, so switching it in settings takes
        // effect without rebuilding the client.
        let domainHolder = DomainHolder(settings.domain)
        self.domainHolder = domainHolder
        let suppliedTransport = transport
        let transport = suppliedTransport ?? URLSessionTransport(
            cookieStorage: .shared,
            cache: URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 128 * 1024 * 1024,
                diskPath: "NeechanResponses"
            )
        )

        // Built before `self` exists, so the hook goes through a box that is
        // filled in below.
        let challenges = ChallengeRelay()
        let client = DvachClient(
            transport: transport,
            domain: domainHolder.provider,
            onChallenge: { [challenges] url in challenges.report(url) }
        )
        self.challenges = challenges

        self.client = client
        self.boards = BoardsRepository(client: client)
        self.catalog = CatalogRepository(client: client)
        self.history = HistoryRepository(modelContainer: modelContainer)

        let drafts = DraftRepository(modelContainer: modelContainer)
        let ownPosts = OwnPostsRepository(modelContainer: modelContainer)
        self.drafts = drafts
        self.ownPosts = ownPosts
        self.captchaClient = client
        let favorites = FavoritesRepository(modelContainer: modelContainer)
        let watchedThreads = WatchedThreadStore(modelContainer: modelContainer)
        self.favorites = favorites
        self.watchedThreads = watchedThreads
        self.hidden = HiddenContentRepository(modelContainer: modelContainer)
        self.watcher = ThreadWatcher(
            client: client, favorites: favorites, states: watchedThreads
        )
        #if canImport(UserNotifications)
        self.notifications = NotificationScheduler()
        #endif

        self.search = SearchService(client: client)
        self.archive = ArchiveRepository(client: client)
        self.savedThreads = SavedThreadsRepository(modelContainer: modelContainer)
        self.themes = ThemeRepository(modelContainer: modelContainer)
        self.backup = BackupService(modelContainer: modelContainer)
        self.cookies = CookieManager(domain: domainHolder.provider)
        self.downloader = Downloader()

        self.posting = PostingCoordinator(
            postingService: PostingService(
                client: client, transport: transport, domain: domainHolder.provider
            ),
            drafts: drafts,
            ownPosts: ownPosts
        )
    }

    /// Whether thumbnails and media may be fetched right now.
    public var allowsMediaLoading: Bool {
        reachability.allowsMedia(under: settings.mediaLoadPolicy)
    }

    /// The device and preference state a poll has to respect.
    public var pollConditions: PollConditions {
        PollConditions(
            isConnected: reachability.isConnected,
            isExpensive: reachability.isExpensive,
            wifiOnly: settings.watcherWiFiOnly,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Whether a poll nobody asked for may go out right now.
    ///
    /// The reader's "only on Wi-Fi" preference, which until now was written
    /// down and never read. Pulling to refresh is a request they made and is
    /// never held back by this; the watcher and the open thread's timer are.
    public var allowsAutomaticPolling: Bool {
        pollConditions.allowsPolling
    }

    /// Starts listening for gate pages. Called once by the shell.
    public func observeChallenges() {
        reachability.start()
        applyHistoryRecordingSetting()
        // Points the watcher at the live network and preference state. Done
        // here rather than in `init`, which cannot read the main actor because
        // it is still building the thing that lives on it.
        Task { [weak self, watcher] in
            await watcher.setConditions {
                await MainActor.run { self?.pollConditions ?? .unrestricted }
            }
        }
        challenges.onReport = { [weak self] url in
            guard let self, pendingChallengeURL == nil else { return }
            pendingChallengeURL = url
        }
    }

    /// Tells the history repository whether it should be recording. Called at
    /// startup and whenever the reader changes the preference.
    public func applyHistoryRecordingSetting() {
        let enabled = settings.remembersHistory
        Task { await history.setRecordingEnabled(enabled) }
    }

    /// Called once the reader has passed the check, so the next failure can
    /// raise it again.
    public func clearPendingChallenge() {
        pendingChallengeURL = nil
    }

    /// A captcha session for one post. Each post gets its own, because a
    /// captcha token is single use.
    public func makeCaptchaSession() -> EmojiCaptchaSession {
        EmojiCaptchaSession(client: client)
    }

    /// How many threads' posts are kept in memory.
    ///
    /// A thread's repository holds every post in it and every parsed comment, so
    /// a long session that wandered through thirty threads used to be holding
    /// all thirty. Anything still open is held by its own view model, so
    /// dropping one here only costs a refetch if the reader goes back to it.
    static let cachedThreadLimit = 8

    /// The repository for one thread, reused while the thread stays open so a
    /// second visit does not refetch what is already held.
    public func threadRepository(for key: ThreadKey) -> ThreadRepository {
        if let existing = threadRepositories[key] {
            threadOrder.removeAll { $0 == key }
            threadOrder.append(key)
            return existing
        }
        let repository = ThreadRepository(key: key, client: client)
        threadRepositories[key] = repository
        threadOrder.append(key)

        while threadOrder.count > Self.cachedThreadLimit, let oldest = threadOrder.first {
            threadOrder.removeFirst()
            threadRepositories[oldest] = nil
        }
        return repository
    }

    /// Frees what can be freed. Called when the system says memory is short.
    public func releaseMemory(keeping keys: Set<ThreadKey> = []) {
        releaseThreads(keeping: keys)
    }

    /// Polls watched threads once and tells the reader about anything new.
    ///
    /// Used by the foreground timer, by pull to refresh, and by the background
    /// task, so the three cannot drift apart.
    public func pollWatchedThreads() async {
        // Bounded: the system gives a background refresh a few seconds and kills
        // it if it overruns. Whatever is not asked about now is asked about next
        // time, oldest first.
        let results = await watcher.pollDue(deadline: .now + .seconds(20))
        #if canImport(UserNotifications)
        guard results.contains(where: \.hasNews) else { return }

        let titles = ((try? await favorites.favorites()) ?? [])
            .reduce(into: [ThreadKey: String]()) { $0[$1.key] = $1.title }
        await notifications.notify(
            about: results,
            titles: titles,
            setting: settings.watcherNotifications
        )
        #endif
    }

    /// Starts the foreground poll at the interval the reader chose.
    public func startWatching() async {
        let setting = settings.watcherNotifications
        await watcher.startPolling(
            every: .seconds(settings.watcherIntervalSeconds)
        ) { [weak self] results in
            guard let self, results.contains(where: \.hasNews) else { return }
            #if canImport(UserNotifications)
            let titles = await MainActor.run { () -> FavoritesRepository in self.favorites }
            let items = (try? await titles.favorites()) ?? []
            await self.notifications.notify(
                about: results,
                titles: items.reduce(into: [ThreadKey: String]()) { $0[$1.key] = $1.title },
                setting: setting
            )
            #endif
        }
    }

    public func stopWatching() async {
        await watcher.stopPolling()
    }

    /// Drops cached threads. Called when the mirror changes or memory is tight.
    public func releaseThreads(keeping keys: Set<ThreadKey> = []) {
        threadRepositories = threadRepositories.filter { keys.contains($0.key) }
        threadOrder = threadOrder.filter { keys.contains($0) }
    }

    /// Points the client at the mirror now selected and drops everything cached
    /// in memory, because paths resolve against the mirror and cookies differ
    /// per host.
    public func handleDomainChange() async {
        let target = settings.domain
        // The session lives in cookies pinned to a host, so the few that are
        // the reader's own are copied across before anything is fetched.
        await cookies.mirror(names: CookieManager.portableCookieNames, to: target)
        domainHolder.set(target)
        await boards.invalidate()
        releaseThreads()
    }

    /// The theme the reader picked, or the built-in one.
    public func currentTheme() async -> NeechanTheme {
        (try? await themes.theme(id: settings.themeID)) ?? .builtIn
    }

    /// Builds the services for previews and tests, backed by an in-memory store.
    public static func inMemory(
        settings: AppSettings = AppSettings(),
        transport: (any HTTPTransport)? = nil
    ) throws -> AppServices {
        AppServices(
            settings: settings,
            modelContainer: try NeechanStore.makeContainer(inMemory: true),
            transport: transport
        )
    }
}

extension AppSettings {
    /// The per-file options a newly attached file starts with.
    ///
    /// A function rather than a property: each call mints a fresh random name,
    /// so two files attached to the same post do not end up sharing one.
    public func newAttachmentProcessing() -> AttachmentProcessing {
        AttachmentProcessing(
            appendsUniqueHash: appendsUniqueHashByDefault,
            stripsMetadata: stripsMetadataByDefault,
            renameTo: removesFileNamesByDefault ? AppSettings.randomFileName() : nil
        )
    }
}


/// Carries a gate page from the client's executor to the main actor.
///
/// The client is built during `AppServices.init`, before `self` can be
/// captured, so the hook is given this box and the box is pointed at the
/// services afterwards.
final class ChallengeRelay: Sendable {
    private let handler = Mutex<(@MainActor (URL) -> Void)?>(nil)

    var onReport: (@MainActor (URL) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    func report(_ url: URL) {
        guard let handler = onReport else { return }
        Task { @MainActor in handler(url) }
    }
}
