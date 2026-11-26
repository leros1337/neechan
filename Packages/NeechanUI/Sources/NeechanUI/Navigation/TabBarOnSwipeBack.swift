#if os(iOS)
import SwiftUI
import UIKit

/// Brings the tab bar back as a swipe out of a thread begins.
///
/// A thread hides the tab bar (`hidesTabBar()`), and SwiftUI shows it again
/// only once the way back has finished. A slow swipe therefore uncovers the
/// board without its bar, and the bar then pops in all at once at the end.
/// This watches the navigation controller's back swipes instead: when one
/// starts and leads to a screen that shows the tabs, the bar is brought up
/// with the system's own animation, rising under the thread as it slides away
/// and over its controls for the moment both are on screen. If the reader
/// gives the swipe up, the bar goes away again.
///
/// Placed behind the thread at no size, where it is never seen or reached by
/// VoiceOver; all it needs is a place in the controller hierarchy.
struct TabBarOnSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Watcher { Watcher() }
    func updateUIViewController(_ controller: Watcher, context: Context) {}

    final class Watcher: UIViewController {
        private var watched: [UIGestureRecognizer] = []

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard watched.isEmpty, let navigation = navigationController else { return }
            // The swipe from the screen's edge, and the one from anywhere on it.
            watched = [
                navigation.interactivePopGestureRecognizer,
                navigation.interactiveContentPopGestureRecognizer,
            ].compactMap { $0 }
            for recognizer in watched { recognizer.addTarget(self, action: #selector(swiped)) }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            for recognizer in watched { recognizer.removeTarget(self, action: #selector(swiped)) }
            watched = []
        }

        @objc private func swiped(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .began else { return }
            // Taken now: once the transition is under way this screen may
            // already be out of the stack, and its parents with it.
            let navigation = navigationController
            let tabs = tabBarController
            // The transition exists only a moment after the swipe begins.
            DispatchQueue.main.async {
                Self.showTabBarIfLeavingForTabs(navigation, tabs)
            }
        }

        /// Whether a screen, or anything shown inside it, keeps the tab bar away.
        private static func hidesTabBar(_ controller: UIViewController) -> Bool {
            controller is Watcher || controller.children.contains(where: hidesTabBar)
        }

        private static func showTabBarIfLeavingForTabs(
            _ navigation: UINavigationController?,
            _ tabs: UITabBarController?
        ) {
            guard
                let tabs,
                let coordinator = navigation?.transitionCoordinator,
                let destination = coordinator.viewController(forKey: .to),
                // A thread under this one hides the bar itself: nothing to bring back.
                !hidesTabBar(destination)
            else { return }
            tabs.setTabBarHidden(false, animated: true)
            coordinator.notifyWhenInteractionChanges { context in
                if context.isCancelled { tabs.setTabBarHidden(true, animated: true) }
            }
        }
    }
}
#endif
