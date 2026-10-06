import NeechanCore
import NeechanSettings
import NeechanUI
import SwiftData
import SwiftUI

@main
struct NeechanApp: App {
    @State private var services: AppServices
    /// Built here rather than by the root view: a launch has to be locked
    /// before its first frame, and a view cannot read the setting that early.
    @State private var lock: AppLock
    @State private var startupError: String?

    init() {
        let settings = AppSettings()
        _lock = State(initialValue: AppLock(isEnabled: settings.locksApp))
        let services: AppServices
        do {
            let container = try NeechanStore.makeContainer()
            services = AppServices(settings: settings, modelContainer: container)
        } catch {
            // A corrupt store must not stop the app from launching: fall back to
            // an in-memory one and say so, rather than crashing on open.
            services = AppServices(
                settings: settings,
                // The current shapes, not a named version: a fallback a
                // schema behind would be a container whose every predicate
                // names a column it has never heard of.
                modelContainer: try! ModelContainer(
                    for: Schema(NeechanStore.currentModels),
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            )
            _startupError = State(initialValue: String(describing: error))
        }
        _services = State(initialValue: services)
        Self.registerLaunchHandlers(services)
    }

    /// Hooks up what the system calls into without a window.
    ///
    /// Here, during launch, because it is the only moment the system accepts
    /// either: the background poll must be registered before the app finishes
    /// launching, and the tap that launched it goes to whichever notification
    /// delegate is set by then. A view's `.task` was too late on both counts,
    /// and never runs at all when the system wakes the app in the background
    /// with no window to show.
    private static func registerLaunchHandlers(_ services: AppServices) {
        #if os(iOS)
        services.notificationResponder.install()
        BackgroundRefresh.register {
            await services.pollWatchedThreads()
        }
        BackgroundRefresh.schedule()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // The board the reader asked to open on is handed over here: the
            // stack has to hold it before the first frame, or the board list
            // shows for a moment and then jumps.
            AdaptiveRootView(
                defaultBoard: services.settings.defaultBoard,
                site: services.settings.imageboard,
                policy: services.contentPolicy
            )
                .environment(services)
                .environment(lock)
                .alert(
                    "Saved data could not be opened",
                    isPresented: .constant(startupError != nil)
                ) {
                    Button("Continue") { startupError = nil }
                } message: {
                    Text(
                        "Favorites and history are unavailable for this session. "
                            + (startupError ?? "")
                    )
                }
        }
    }
}
