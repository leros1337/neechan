import Foundation

/// Lets one playback test run at a time.
///
/// Swift Testing runs separate suites in parallel even when each is
/// `.serialized`, and these are not cheap neighbours: every one of them opens
/// a file, starts three threads and a clock, and then asserts about what
/// happens within a certain number of seconds. Several at once, some
/// deliberately waiting on a slowed connection, and the timing they assert on
/// stops being about the player at all.
///
/// Nothing in the app needs this. It is a statement about the test machine.
actor PlayerTestGate {
    static let shared = PlayerTestGate()

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Waits for a turn. Paired with `leave`, which a `defer` can call.
    func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func handOver() {
        guard let next = waiting.first else {
            isBusy = false
            return
        }
        waiting.removeFirst()
        next.resume()
    }

    /// Gives the turn up. Safe to call from a `defer`, which cannot await.
    nonisolated func leave() {
        Task { await handOver() }
    }
}
