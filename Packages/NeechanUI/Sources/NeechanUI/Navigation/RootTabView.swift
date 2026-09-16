import NeechanAPI
import NeechanCore
import NeechanSettings
import SwiftUI

/// The app shell: a Liquid Glass tab bar over the content layer.
///
/// The tab bar minimizes as the reader scrolls, and search lives in its own
/// capsule via `Tab(role: .search)`. Nothing here paints glass itself; the
/// navigation chrome supplied by the system is the glass layer, and the screens
/// below render plain content. `Glass/` holds the few places where the app does
/// apply the material by hand.
public struct RootTabView: View {
    @Environment(Router.self) private var router

    public init() {}

    public var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            Tab(value: AppTab.boards) {
                NavigationStack(path: $router.boardsPath) {
                    BoardsListView()
                        .navigationDestination(for: AppRoute.self) { RouteDestinationView(route: $0) }
                }
                .environment(\.layoutDirection, .leftToRight)
            } label: {
                Label {
                    AppTab.boards.title
                } icon: {
                    Image(systemName: AppTab.boards.systemImage)
                }
            }

            Tab(value: AppTab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppRoute.self) { RouteDestinationView(route: $0) }
                }
                .environment(\.layoutDirection, .leftToRight)
            } label: {
                Label {
                    AppTab.settings.title
                } icon: {
                    Image(systemName: AppTab.settings.systemImage)
                }
            }

            Tab(value: AppTab.history) {
                NavigationStack(path: $router.historyPath) {
                    HistoryView()
                        .navigationDestination(for: AppRoute.self) { RouteDestinationView(route: $0) }
                }
                .environment(\.layoutDirection, .leftToRight)
            } label: {
                Label {
                    AppTab.history.title
                } icon: {
                    Image(systemName: AppTab.history.systemImage)
                }
            }

            Tab(value: AppTab.favorites) {
                NavigationStack(path: $router.favoritesPath) {
                    FavoritesView()
                        .navigationDestination(for: AppRoute.self) { RouteDestinationView(route: $0) }
                }
                .environment(\.layoutDirection, .leftToRight)
            } label: {
                Label {
                    AppTab.favorites.title
                } icon: {
                    Image(systemName: AppTab.favorites.systemImage)
                }
            }
        }
        #if os(iOS)
        // Only iOS and iPadOS minimise the tab bar on scroll; the package builds
        // for macOS so its pure logic can be tested without a simulator.
        .tabBarMinimizeBehavior(.onScrollDown)
        // The minimised tab bar collapses to a pill at the *leading* edge, and
        // neither SwiftUI nor UIKit offers a way to choose which edge that is:
        // `TabBarMinimizeBehavior` says when it collapses, never where it goes.
        // Mirroring the bar puts the pill under the thumb instead of across the
        // screen from it. Only the bar is mirrored — each tab's content sets
        // the direction back — and the tabs are declared in reverse so they
        // still read Favorites, History, Settings, Boards from left to right,
        // with Boards under the thumb.
        .environment(\.layoutDirection, .rightToLeft)
        #endif
    }
}
