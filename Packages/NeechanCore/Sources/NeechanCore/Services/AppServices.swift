import Foundation
import os
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
    /// Bridges the main-actor settings to the client, which reads the site and
    /// mirror from its own executor.
    @ObservationIgnored private let siteHolder: SiteHolder
    @ObservationIgnored private let policyHolder: ContentPolicyHolder
    @ObservationIgnored private let challenges: ChallengeRelay

    public init(
        settings: AppSettings,
        modelContainer: ModelContainer,
        transport: (any HTTPTransport)? = nil
    ) {
        self.settings = settings

        // The site and mirror are read on every request, so switching either in
        // settings takes effect without rebuilding the client.
        let siteHolder = SiteHolder(settings.siteSelection)
        self.siteHolder = siteHolder

        // Read the same way and for the same reason: the repositories ask it
        // per query, from their own actor, so turning a restriction on takes
        // effect without rebuilding any of them.
        let policyHolder = ContentPolicyHolder(
            ContentPolicy(
                allowsMatureBoards: settings.allowsMatureBoards,
                listsEveryBoard: !settings.isAppStore
            )
        )
        self.policyHolder = policyHolder
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
            site: siteHolder.provider,
            onChallenge: { [challenges] url in challenges.report(url) }
        )
        self.challenges = challenges

        self.client = client
        self.boards = BoardsRepository(
            client: client, site: siteHolder.provider, policy: policyHolder.provider
        )
        self.catalog = CatalogRepository(client: client)
        self.history = HistoryRepository(
            modelContainer: modelContainer, policy: policyHolder.provider
        )

        let drafts = DraftRepository(modelContainer: modelContainer)
        let ownPosts = OwnPostsRepository(modelContainer: modelContainer)
        self.drafts = drafts
        self.ownPosts = ownPosts
        self.captchaClient = client
        let favorites = FavoritesRepository(
            modelContainer: modelContainer, policy: policyHolder.provider
        )
        let watchedThreads = WatchedThreadStore(modelContainer: modelContainer)
        self.favorites = favorites
        self.watchedThreads = watchedThreads
        self.hidden = HiddenContentRepository(
            modelContainer: modelContainer, policy: policyHolder.provider
        )
        self.watcher = ThreadWatcher(
            client: client,
            site: siteHolder.provider,
            favorites: favorites,
            states: watchedThreads
        )
        #if canImport(UserNotifications)
        self.notifications = NotificationScheduler()
        #endif

        self.search = SearchService(client: client)
        self.archive = ArchiveRepository(client: client)
        self.savedThreads = SavedThreadsRepository(
            modelContainer: modelContainer, policy: policyHolder.provider
        )
        self.themes = ThemeRepository(modelContainer: modelContainer)
        self.backup = BackupService(modelContainer: modelContainer)
        self.cookies = CookieManager(site: siteHolder.provider)
        self.downloader = Downloader()

        self.posting = PostingCoordinator(
            postingService: PostingService(
                client: client, transport: transport, site: siteHolder.provider
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
            // Not straight back up after being dismissed. A gate that refuses
            // the retry as well would otherwise reopen the check the instant it
            // closed, over and over, with nothing for the reader to answer.
            // Whatever failed says so in its own error instead.
            if let dismissedAt = challengeDismissedAt,
               Date.now.timeIntervalSince(dismissedAt) < Self.challengeCooldown {
                return
            }
            Self.log.notice("raising a check for \(url.absoluteString, privacy: .public)")
            pendingChallengeURL = url
        }
    }

    /// Tells the history repository whether it should be recording. Called at
    /// startup and whenever the reader changes the preference.
    public func applyHistoryRecordingSetting() {
        let enabled = settings.remembersHistory
        Task { await history.setRecordingEnabled(enabled) }
    }

    private static let log = Logger(subsystem: Signposts.subsystem, category: "browser-check")

    /// How long after a check closes before another may be raised.
    private static let challengeCooldown: TimeInterval = 10

    /// When the last check was closed, passed or cancelled.
    @ObservationIgnored private var challengeDismissedAt: Date?

    /// Bumped whenever a browser check is passed.
    ///
    /// A screen that was refused because of one keys its own reload on this:
    /// passing the check in a sheet is the moment its request would succeed,
    /// and without a signal it sits on the error it was left with.
    public private(set) var challengesPassed = 0

    /// Waiters for the next browser check to be passed.
    @ObservationIgnored private var challengeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until a browser check is passed.
    ///
    /// For the screens whose request a gate refused: they can wait for the
    /// moment it would succeed and ask again. Deliberately not left to a view
    /// noticing `challengesPassed` change — the check is answered in a window of
    /// its own, and a screen underneath it does not reliably re-evaluate while
    /// that window is key, which left the reader looking at an error after they
    /// had already passed the check.
    public func awaitChallengePass() async {
        await withCheckedContinuation { continuation in
            challengeWaiters.append(continuation)
        }
    }

    /// Takes the cookies a web view collected and tells the app it happened.
    public func adoptChallengeCookies(_ cookies: [HTTPCookie]) async {
        Self.log.notice(
            "adopting \(cookies.count, privacy: .public) cookies: \(cookies.map(\.name).sorted().joined(separator: ","), privacy: .public)"
        )
        await self.cookies.adopt(cookies)
        // Passing one earns a fresh go: the cooldown is there to stop a check
        // nobody answered from reappearing, not to hold up one that worked.
        challengeDismissedAt = nil
        challengesPassed += 1

        let waiters = challengeWaiters
        challengeWaiters.removeAll()
        Self.log.notice("waking \(waiters.count, privacy: .public) waiter(s)")
        for waiter in waiters { waiter.resume() }
    }

    public func clearPendingChallenge() {
        guard pendingChallengeURL != nil else { return }
        pendingChallengeURL = nil
        challengeDismissedAt = .now
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

        let titles = ((try? await favorites.favorites(site: site)) ?? [])
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
        let site = self.site
        await watcher.startPolling(
            every: .seconds(settings.watcherIntervalSeconds)
        ) { [weak self] results in
            guard let self, results.contains(where: \.hasNews) else { return }
            #if canImport(UserNotifications)
            let titles = await MainActor.run { () -> FavoritesRepository in self.favorites }
            let items = (try? await titles.favorites(site: site)) ?? []
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
        siteHolder.set(settings.siteSelection)
        await boards.invalidate()
        releaseThreads()
    }

    /// Chooses the imageboard.
    ///
    /// The one way to change it, because the change has to happen in a
    /// particular order: the client is re-pointed *here*, synchronously, before
    /// the setting is observable to anything else. Writing the setting on its
    /// own left a race — the board list reloads the moment it sees the new
    /// value, and if the client had not been re-pointed yet it fetched the site
    /// the reader had just left and cached the answer against the new one.
    ///
    /// Everything that can wait — stopping the watcher, dropping open threads,
    /// clearing notifications — is left to `handleSiteChange()`, which the
    /// shell runs straight afterwards.
    public func select(_ site: Imageboard) {
        guard site != settings.imageboard else { return }
        settings.imageboard = site
        siteHolder.set(settings.siteSelection)
    }

    /// Points everything at the imageboard now selected.
    ///
    /// Unlike a mirror change, nothing survives: the client is re-pointed at a
    /// different site's API, so every cached board list, open thread and
    /// in-flight poll belongs somewhere else.
    ///
    /// Cookies are deliberately not carried across. A 2ch passcode is a paid
    /// session token, and copying it onto another imageboard's host would put
    /// it in a third party's access logs; `CookieManager.mirror` is for mirrors
    /// and is not called from here.
    ///
    /// The media caches are deliberately *not* cleared either. They key on the
    /// absolute URL, and 4chan's paths arrive absolute while 2ch's resolve
    /// against 2ch's host, so the two cannot collide — and throwing away the
    /// reader's cached images every time they flip a control they will flip
    /// often would cost a great deal for no correctness at all.
    public func handleSiteChange() async {
        // Already done by `select(_:)` on the way in; repeated because this is
        // also reached when the setting is restored from elsewhere, and setting
        // it twice costs nothing.
        siteHolder.set(settings.siteSelection)

        // A poll already awaiting a reply would otherwise finish against the
        // new site and write its count onto the old site's thread. The holder
        // is set before this, so the guard inside the watcher's own poll drops
        // any answer that arrives from here on.
        await stopWatching()
        await watcher.reset()

        await boards.invalidate()
        // Keeping nothing: each cached thread repository holds the one client,
        // which has just been pointed somewhere else.
        releaseThreads()
        pendingChallengeURL = nil
        #if canImport(UserNotifications)
        await notifications.clearAll()
        #endif

        await startWatching()
    }

    /// The imageboard everything is pointed at. The one place views read it.
    public var site: Imageboard { settings.imageboard }

    /// What the selected imageboard can do. Views gate on this rather than on
    /// the site, so a third one needs no edits to any view.
    ///
    /// Deliberately a pure function of the site: what the reader has turned off
    /// is a separate question, asked through `allowsPosting` and
    /// `contentPolicy`. Folding the two together would make "4chan cannot do
    /// this" and "this reader asked us not to" indistinguishable.
    public var capabilities: SiteCapabilities { .of(settings.imageboard) }

    /// Whether a reply can be written at all: the site has to offer posting and
    /// the reader has to have left it on.
    public var allowsPosting: Bool { capabilities.posting && settings.allowsPosting }

    /// What the reader has said they are willing to be shown. For main-actor
    /// readers; the repositories get the same value through their provider.
    public var contentPolicy: ContentPolicy {
        ContentPolicy(
            allowsMatureBoards: settings.allowsMatureBoards,
            // Fixed by the build, not by the reader, so nothing ever moves it.
            listsEveryBoard: !settings.isAppStore
        )
    }

    /// Turns the gate on boards meant for adults on or off.
    ///
    /// Goes through here rather than through `settings` directly so the holder
    /// the repositories read moves in the same synchronous step: a list rebuilt
    /// in this same turn would otherwise still be filtering on the old answer.
    /// The same discipline `select(_:)` needs for the imageboard.
    public func setMatureAllowed(_ allowed: Bool) {
        guard allowed != settings.allowsMatureBoards else { return }
        settings.allowsMatureBoards = allowed
        policyHolder.set(contentPolicy)
    }

    /// Re-reads the restrictions into the value the repositories share.
    ///
    /// `setMatureAllowed` already does this, and is the only writer today. The
    /// shell calls this whenever the preference moves so that a second writer
    /// added later cannot leave the repositories answering the old question
    /// while every view answers the new one.
    public func refreshContentPolicy() {
        policyHolder.set(contentPolicy)
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
