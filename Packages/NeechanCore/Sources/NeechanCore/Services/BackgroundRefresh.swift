#if os(iOS)
import BackgroundTasks
import Foundation

/// Registers and schedules the watcher's background poll.
///
/// The system decides when, and may not run it for hours, so this is a bonus on
/// top of the foreground timer rather than the thing readers rely on.
public enum BackgroundRefresh {
    public static let taskIdentifier = "com.lain.neechan.watcher"

    /// Registers the handler. Must be called before the app finishes launching.
    public static func register(handler: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: .main
        ) { task in
            // Always schedule the next one first: a run that crashes or expires
            // would otherwise be the last one ever.
            schedule()

            // `BGTask` is not `Sendable`, and the launch handler is. The task is
            // boxed to carry it across: the scheduler was asked to deliver on the
            // main queue, and every use below is on the main actor, so the box is
            // never touched from two places at once.
            let completion = TaskCompletion(task)
            let work = Task { @MainActor in
                await handler()
                completion.finish(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                Task { @MainActor in completion.finish(success: false) }
            }
        }
    }

    /// Carries the non-`Sendable` task to the main actor and reports completion
    /// exactly once: the system treats a second report as a programming error
    /// and terminates the app.
    private final class TaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private var hasFinished = false

        init(_ task: BGTask) {
            self.task = task
        }

        @MainActor
        func finish(success: Bool) {
            guard !hasFinished else { return }
            hasFinished = true
            task.setTaskCompleted(success: success)
        }
    }

    /// Asks for another run, no sooner than `earliest`.
    public static func schedule(earliest: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
