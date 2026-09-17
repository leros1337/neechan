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
        do {
            let container = try NeechanStore.makeContainer()
            _services = State(initialValue: AppServices(settings: settings, modelContainer: container))
        } catch {
            // A corrupt store must not stop the app from launching: fall back to
            // an in-memory one and say so, rather than crashing on open.
            _services = State(
                initialValue: AppServices(
                    settings: settings,
                    modelContainer: try! ModelContainer(
                        for: Schema(NeechanSchemaV1.models),
                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                    )
                )
            )
            _startupError = State(initialValue: String(describing: error))
        }
    }

    /// Registers the background poll before the app finishes launching, which
    /// is the only moment the system accepts it.
    private func registerBackgroundRefresh() {
        #if os(iOS)
        let services = self.services
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
            AdaptiveRootView(defaultBoard: services.settings.defaultBoard)
                .environment(services)
                .environment(lock)
                .task { registerBackgroundRefresh() }
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
