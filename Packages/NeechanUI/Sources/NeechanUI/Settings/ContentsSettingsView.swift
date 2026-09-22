import NeechanCore
import NeechanSettings
import SwiftUI

/// How threads refresh themselves and how the watcher behaves.
struct ContentsSettingsView: View {
    @Environment(AppServices.self) private var services

    /// Offered intervals, in seconds. Zero is "never".
    private let refreshChoices = [0, 15, 30, 60, 120, 300]

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Picker(selection: $settings.autoRefreshIntervalSeconds) {
                    ForEach(refreshChoices, id: \.self) { seconds in
                        intervalLabel(seconds).tag(seconds)
                    }
                } label: {
                    Text("Refresh an open thread", bundle: .module)
                }

                Picker(selection: $settings.endlessThreadMode) {
                    Text("As you scroll", bundle: .module).tag(EndlessThreadMode.default)
                    Text("Load everything", bundle: .module).tag(EndlessThreadMode.fullLoad)
                    Text("Load everything, drop the oldest", bundle: .module)
                        .tag(EndlessThreadMode.fullLoadWithCleanup)
                } label: {
                    Text("Long threads", bundle: .module)
                }
            } header: {
                Text("Threads", bundle: .module)
            }

            Section {
                Picker(selection: $settings.unreadMarkerMode) {
                    Text("Automatic", bundle: .module).tag(UnreadMarkerMode.automatic)
                    Text("Manual", bundle: .module).tag(UnreadMarkerMode.manual)
                    Text("Never", bundle: .module).tag(UnreadMarkerMode.never)
                } label: {
                    Text("New post marker", bundle: .module)
                }
            } footer: {
                Text("Automatic marks a post read once you have scrolled past it.", bundle: .module)
            }

            Section {
                Picker(selection: $settings.favoritesOrder) {
                    Text("Unread first", bundle: .module).tag(FavoritesOrder.unreadFirst)
                    Text("Newest first", bundle: .module).tag(FavoritesOrder.newestFirst)
                    Text("Oldest first", bundle: .module).tag(FavoritesOrder.oldestFirst)
                    Text("By title", bundle: .module).tag(FavoritesOrder.title)
                } label: {
                    Text("Order", bundle: .module)
                }
                // A build that never replies can never trip this one. The
                // rest of the section is about reading and stays.
                if settings.allowsPosting {
                    Toggle(isOn: $settings.favoritesOnReply) {
                        Text("Add to favorites when I reply", bundle: .module)
                    }
                }
                Toggle(isOn: $settings.watchesNewFavorites) {
                    Text("Watch new favorites", bundle: .module)
                }
            } header: {
                Text("Favorites", bundle: .module)
            }

            Section {
                Picker(selection: notificationsBinding) {
                    ForEach(settings.watcherNotificationChoices) { choice in
                        label(for: choice).tag(choice)
                    }
                } label: {
                    Text("Notifications", bundle: .module)
                }
                .accessibilityIdentifier("watcher-notifications")

                Stepper(value: $settings.watcherIntervalSeconds, in: 15...600, step: 15) {
                    Text(
                        "Check every \(services.settings.watcherIntervalSeconds) seconds",
                        bundle: .module
                    )
                }

                Toggle(isOn: $settings.watcherWiFiOnly) {
                    Text("Only on Wi-Fi", bundle: .module)
                }
            } header: {
                Text("Watcher", bundle: .module)
            } footer: {
                Text("The watcher checks favorited threads for new posts.", bundle: .module)
            }
        }
        .navigationTitle(Text("Contents", bundle: .module))
        .inlineNavigationTitle()
        // Debounced. The stepper fires on every tap, and restarting the watcher
        // is not free; dragging from fifteen seconds to ten minutes used to
        // restart it thirty-nine times.
        .task(id: services.settings.watcherIntervalSeconds) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await services.startWatching()
        }
    }

    private func label(for choice: WatcherNotificationSetting) -> Text {
        switch choice {
        case .off: Text("Off", bundle: .module)
        case .repliesOnly: Text("Replies to me", bundle: .module)
        case .allNewPosts: Text("All new posts", bundle: .module)
        }
    }

    private func intervalLabel(_ seconds: Int) -> Text {
        seconds == 0
            ? Text("Never", bundle: .module)
            : Text("Every \(seconds) seconds", bundle: .module)
    }

    private var notificationsBinding: Binding<WatcherNotificationSetting> {
        Binding(
            get: { services.settings.watcherNotifications },
            set: { newValue in
                services.settings.watcherNotifications = newValue
                #if canImport(UserNotifications)
                // Ask only when the reader actually turns them on.
                if newValue != .off {
                    Task { await services.notifications.requestAuthorization() }
                }
                #endif
            }
        )
    }
}
