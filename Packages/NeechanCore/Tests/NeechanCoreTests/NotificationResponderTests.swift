#if canImport(UserNotifications)
import Foundation
import NeechanAPI
import Testing
@testable import NeechanCore

/// A tapped banner is handed over with a completion handler that UIKit insists
/// on being called on the main thread; called anywhere else, the app crashes
/// the moment the reader taps. The async form of the delegate method called it
/// from the cooperative pool, which is how tapping a reply banner crashed.
@Suite("Notification responder")
@MainActor
struct NotificationResponderTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)

    /// Hands the response over from a background thread, as the centre may,
    /// and reports whether the completion ran on the main thread.
    private func answer(
        _ payload: NotificationPayload?,
        with responder: NotificationResponder
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            Task.detached {
                responder.handleResponse(payload) {
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
        }
    }

    @Test("a tap is answered on the main thread and leads to its post")
    func tapIsAnsweredOnMain() async {
        let responder = NotificationResponder()
        let payload = NotificationPayload(key: key, postNum: 7)

        let onMain = await answer(payload, with: responder)

        #expect(onMain)
        #expect(responder.pendingTarget == payload.target)
    }

    @Test("a dismissal is answered on the main thread and goes nowhere")
    func dismissalIsAnsweredOnMain() async {
        let responder = NotificationResponder()

        let onMain = await answer(nil, with: responder)

        #expect(onMain)
        #expect(responder.pendingTarget == nil)
    }
}
#endif
