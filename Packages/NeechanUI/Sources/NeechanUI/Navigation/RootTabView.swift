import NeechanAPI
import NeechanCore
import NeechanSettings
import SwiftUI

/// The app shell: a Liquid Glass tab bar over the content layer.
///
/// The tab bar minimizes as the reader scrolls. Nothing here paints glass
/// itself; the navigation chrome supplied by the system is the glass layer,
/// and the screens below render plain content.
///
/// On iPhone Duo the system stacks this bar down the side of the outer display
/// instead. The order below is what it uses top to bottom -- Boards first,
/// which is the primary destination and what the HIG asks to find at the top
/// of a vertical axis -- so the declaration order carries both layouts.
public struct RootTabView: View {
    @Environment(Router.self) private var router
    /// Which side the system would stack the bars down, or `nil` where it never
    /// would. A trait rather than a measurement, so it is settled before the
    /// first frame and does not depend on the layout direction set below.
    @Environment(\.duoVerticalBarEdge) private var verticalBarEdge

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
        }
        #if os(iOS)
        // Only iOS and iPadOS minimise the tab bar on scroll; the package builds
        // for macOS so its pure logic can be tested without a simulator.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Mirrored only while the bar runs across the bottom.
        //
        // The minimized tab bar collapses to a pill at the *leading* edge, and
        // neither SwiftUI nor UIKit offers a way to choose which edge that is:
        // `TabBarMinimizeBehavior` says when it collapses, never where it goes.
        // Mirroring the bar puts the pill under the thumb instead of across the
        // screen from it. Only the bar is mirrored -- each tab's content sets
        // the direction back -- and the tabs are declared in reverse so they
        // still read Settings, Favorites, History, Boards from left to right,
        // with Boards under the thumb. The first one written is the rightmost.
        //
        // None of that applies once the system stacks the bar down the side, as
        // it does on iPhone Duo's outer display: there is no pill to move, and
        // the mirror only pushes the bar to the edge opposite the camera and
        // the status bar, which the hardware fixes and does not mirror. Left to
        // right there, so the app's controls land on the same side as the
        // system's. The vertical order is the declaration order either way, so
        // it reads Boards first -- the primary destination at the top of the
        // axis, which is where the guidance asks for it.
        .environment(\.layoutDirection, verticalBarEdge == nil ? .rightToLeft : .leftToRight)
        #endif
    }
}
