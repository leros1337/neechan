import NeechanCore
import NeechanSettings
import NeechanUI
import SwiftData
import SwiftUI

@main
struct NeechanApp: App {
    @State private var services: AppServices
    @State private var startupError: String?

    init() {
        let settings = AppSettings()
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
            AdaptiveRootView()
                .environment(services)
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
