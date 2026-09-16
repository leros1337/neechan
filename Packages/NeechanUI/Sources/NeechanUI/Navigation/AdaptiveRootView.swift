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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var router = Router()
    @State private var theme: NeechanTheme = .builtIn
    /// When the app last came to the front, for the usage total.
    @State private var becameActiveAt: Date?

    public init() {}

    public var body: some View {
        shell
            .environment(router)
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
            .sheet(item: challengeItem) { challenge in
                CloudflareChallengeSheet(url: challenge.url)
            }
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
                    await services.startWatching()
                case .background, .inactive:
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

    /// The gate page to show, as an identifiable value so the sheet can be
    /// driven by it and cleared when it is dismissed.
    private var challengeItem: Binding<ChallengeItem?> {
        Binding(
            get: { services.pendingChallengeURL.map(ChallengeItem.init) },
            set: { if $0 == nil { services.clearPendingChallenge() } }
        )
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

/// The gate page the shell is showing.
struct ChallengeItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The screen a route leads to.
///
/// One place, so the tab shell and the split shell can never drift apart on
/// what a route means.
struct RouteDestinationView: View {
    let route: AppRoute

    var body: some View {
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
