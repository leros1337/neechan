import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// The app shell, in whichever shape the window can hold.
///
/// A phone gets the tab bar. A window wide enough for two columns gets a
/// sidebar instead, because an iPad has the room to keep the section list on
/// screen while a thread is open.
public struct AdaptiveRootView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var router: Router
    @State private var theme: NeechanTheme = .builtIn
    /// When the app last came to the front, for the usage total.
    @State private var becameActiveAt: Date?

    /// - Parameters:
    ///   - defaultBoard: the board the reader asked the app to open on, if any.
    ///     Taken here rather than read from settings inside, because the stack
    ///     has to hold it before the first frame is drawn.
    ///   - site: the imageboard that board is on, for the same reason.
    ///   - policy: the reader's restrictions, for the same reason again: the
    ///     board in settings may be one they have since decided not to see.
    public init(
        defaultBoard: String? = nil,
        site: Imageboard = .default,
        policy: ContentPolicy = .unrestricted
    ) {
        _router = State(initialValue: Router(defaultBoard: defaultBoard, site: site, policy: policy))
    }

    public var body: some View {
        shell
            // Over everything, in a window of its own, so a sheet or the
            // gallery cannot be left showing through it.
            .appLockCover(lock)
            .environment(router)
            // Both site switches are handled here rather than on the controls
            // that fire them: the imageboard can be changed from the board
            // list, from the forum settings or by opening a pasted link from
            // the other site, and one handler is the only way those cannot
            // drift. The mirror handler was on a leaf view and so never ran
            // when the mirror was changed from anywhere else.
            .onChange(of: services.settings.imageboard) {
                router.resetForSiteChange(
                    defaultBoard: services.settings.defaultBoard,
                    site: services.settings.imageboard
                )
                Task { await services.handleSiteChange() }
            }
            // Same reasoning as the two above: a restriction can be turned on
            // from the Restrictions screen while the reader is standing inside
            // a board it covers, and there is one shell to walk them out of it.
            .onChange(of: services.settings.allowsMatureBoards) {
                services.refreshContentPolicy()
                router.policy = services.contentPolicy
                router.pruneBlocked()
            }
            .onChange(of: services.settings.domain) {
                Task { await services.handleDomainChange() }
            }
            .tint(Color(theme.accent))
            .environment(\.neechanTheme, theme)
            .environment(\.locale, appLocale)
            // SwiftUI reads the environment; strings built in code cannot, so
            // the same choice is published where the lower layers can see it.
            .task(id: services.settings.languageCode) {
                AppLocale.set(services.settings.languageCode.map(Locale.init(identifier:)))
            }
            .preferredColorScheme(preferredColorScheme)
            .task(id: services.settings.themeID) {
                theme = await services.currentTheme()
            }
            // The watcher runs only while the app is in front; background
            // polling is the system's to schedule.
            .task {
                // Before anything else asks the site who we are.
                await NativeUserAgent.adopt()
                services.observeChallenges()
                // The reader's cache budget, applied at launch. It used to be
                // read only when they touched the stepper, so every launch went
                // back to the built-in half a gigabyte.
                await MediaCache.shared.setByteLimit(
                    services.settings.mediaCacheLimitMegabytes * 1024 * 1024
                )
                // And how long they asked to keep it. Applying this at launch is
                // what actually clears out what has gone stale: eviction other-
                // wise only runs on the way to the background.
                await MediaCache.shared.setMaxAge(
                    days: services.settings.mediaCacheMaxAgeDays
                )
                await services.startWatching()
            }
            // In a window of its own rather than a sheet here: the request a
            // gate refuses first is the captcha, which is asked for from inside
            // the reply form — itself a sheet — and SwiftUI will not present a
            // second sheet over one already up.
            .browserCheckCover(services)
            .onChange(of: scenePhase) { _, phase in
                recordTime(for: phase)
            }
            // The one signal the system gives before it starts killing apps.
            // Event-driven, so it costs nothing until it fires.
            #if os(iOS)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                releaseMemory()
            }
            #endif
            // Keyed rather than fired from `onChange`, so the calls cannot land
            // out of order: two loose tasks racing meant a quick trip to Control
            // Center could stop the watcher after it had been started, or leave
            // it running with the app in the background.
            .task(id: scenePhase) {
                switch scenePhase {
                case .active:
                    // The lock first: what it decides here is whether anything
                    // below is allowed to be on screen at all.
                    lock.sceneBecameActive()
                    await services.startWatching()
                case .background, .inactive:
                    // Being made inactive covers the app; only leaving the
                    // screen starts the clock on asking again.
                    if scenePhase == .background {
                        lock.sceneEnteredBackground()
                    } else {
                        lock.sceneBecameInactive()
                    }
                    await services.stopWatching()
                    // Going away is the one moment there is time to tidy up and
                    // nobody is waiting on the disk.
                    if scenePhase == .background {
                        await MediaCache.shared.evictIfNeeded()
                    }
                @unknown default:
                    break
                }
            }
    }

    /// Drops what can be rebuilt: decoded images, rendered post bodies, and the
    /// posts of threads the reader is not currently in.
    private func releaseMemory() {
        PostBodyCache.shared.removeAll()
        Task { await ImageLoader.shared.clearMemoryCache() }
        services.releaseMemory(keeping: router.openThreadKeys)
    }

    @ViewBuilder
    private var shell: some View {
        if sizeClass == .compact {
            RootTabView()
        } else {
            SplitRootView()
        }
    }

    /// Adds the stretch just spent in the app to the usage total.
    ///
    /// Measured between becoming active and leaving, so time with the app in
    /// the background is not counted as time using it.
    private func recordTime(for phase: ScenePhase) {
        switch phase {
        case .active:
            becameActiveAt = .now
        case .inactive, .background:
            if let becameActiveAt {
                services.settings.addTimeInApp(seconds: Date.now.timeIntervalSince(becameActiveAt))
            }
            becameActiveAt = nil
        @unknown default:
            break
        }
    }

    /// The language the app draws itself in.
    ///
    /// Applied as the environment's locale, which is what SwiftUI looks strings
    /// up against, so switching takes effect at once rather than on the next
    /// launch.
    private var appLocale: Locale {
        services.settings.languageCode.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// The appearance the reader pinned, or nil to follow the system.
    private var preferredColorScheme: ColorScheme? {
        switch services.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The screen a route leads to.
///
/// One place, so the tab shell and the split shell can never drift apart on
/// what a route means.
struct RouteDestinationView: View {
    @Environment(Router.self) private var router

    let route: AppRoute

    var body: some View {
        // The belt behind `Router`'s guards: a route can already be on a stack
        // at the moment a restriction is turned on, and this is drawn before
        // the shell has walked the reader out of it.
        if !router.allows(route) {
            RestrictedRouteView()
        } else {
            destination
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .board(let board):
            ThreadsListView(board: board)
        case .thread(let key, let scrollTo):
            ThreadView(key: key, scrollTo: scrollTo)
        case .savedThread(let key):
            ThreadView(key: key, offline: true)
        case .archive(let board):
            ArchiveView(board: board)
        case .serverSearch(let board):
            ServerSearchView(board: board)
        case .userBoards:
            UserBoardsView()
        case .statistics:
            StatisticsView()
        }
    }
}

/// Shown in place of a screen the reader's restrictions cover.
///
/// Says which setting is responsible, because a screen that simply refuses to
/// appear reads as a broken app rather than as a choice the reader made.
struct RestrictedRouteView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Not available", bundle: .module)
            } icon: {
                Image(systemName: "hand.raised")
            }
        } description: {
            Text("This board is turned off in Settings, under Restrictions.", bundle: .module)
        }
        .accessibilityIdentifier("restricted-route")
    }
}

/// The iPad shell: sections on the left, everything else on the right.
///
/// Two columns rather than three. The board list, the thread list and the
/// thread are one line of travel, and splitting them across two columns would
/// leave the third holding a thread at half the width it wants.
struct SplitRootView: View {
    @Environment(Router.self) private var router
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var router = router

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: selection) {
                ForEach(AppTab.allCases) { tab in
                    NavigationLink(value: tab) {
                        Label {
                            tab.title
                        } icon: {
                            Image(systemName: tab.systemImage)
                        }
                    }
                }
            }
            .navigationTitle(Text("Neechan", bundle: .module))
        } detail: {
            NavigationStack(path: $router.activePath) {
                root(for: router.selectedTab)
                    .navigationDestination(for: AppRoute.self) { route in
                        RouteDestinationView(route: route)
                    }
            }
        }
    }

    /// The sidebar's selection. A split view hands back nothing when the reader
    /// deselects, which should leave the section where it was rather than
    /// emptying the detail column.
    private var selection: Binding<AppTab?> {
        Binding(
            get: { router.selectedTab },
            set: { if let newValue = $0 { router.selectedTab = newValue } }
        )
    }

    @ViewBuilder
    private func root(for tab: AppTab) -> some View {
        switch tab {
        case .favorites: FavoritesView()
        case .history: HistoryView()
        case .settings: SettingsView()
        case .boards: BoardsListView()
        }
    }
}
