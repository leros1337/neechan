import Foundation
import Testing
@testable import NeechanCore

/// When coming back to a board is worth a fetch.
@Suite("Board refresh policy")
struct BoardRefreshPolicyTests {
    private let loadedAt = Date(timeIntervalSince1970: 1_000_000)

    private func shouldRefresh(
        secondsSinceLoad: TimeInterval? = 120,
        staleAfter: Duration = .seconds(60),
        isNearTop: Bool = true,
        isLoading: Bool = false,
        allowsAutomaticPolling: Bool = true
    ) -> Bool {
        BoardRefreshPolicy.shouldRefresh(
            lastLoadedAt: secondsSinceLoad == nil ? nil : loadedAt,
            now: loadedAt.addingTimeInterval(secondsSinceLoad ?? 0),
            staleAfter: staleAfter,
            isNearTop: isNearTop,
            isLoading: isLoading,
            allowsAutomaticPolling: allowsAutomaticPolling
        )
    }

    @Test("a list older than the window is worth replacing")
    func staleRefreshes() {
        #expect(shouldRefresh(secondsSinceLoad: 120))
    }

    /// Reading three threads in a row should cost one fetch, not three.
    @Test("a list fetched a moment ago is left alone")
    func freshIsLeftAlone() {
        #expect(shouldRefresh(secondsSinceLoad: 10) == false)
    }

    @Test("the window itself counts as stale")
    func theBoundary() {
        #expect(shouldRefresh(secondsSinceLoad: 60, staleAfter: .seconds(60)))
        #expect(shouldRefresh(secondsSinceLoad: 59, staleAfter: .seconds(60)) == false)
    }

    /// A board is ordered by what was last bumped, so a refresh moves rows.
    @Test("a reader part way down the board keeps their place")
    func scrolledAwayIsLeftAlone() {
        #expect(shouldRefresh(isNearTop: false) == false)
    }

    @Test("nothing is asked for twice at once")
    func alreadyLoading() {
        #expect(shouldRefresh(isLoading: true) == false)
    }

    /// Nobody asked for this one, so it waits for Wi-Fi where the reader said to.
    @Test("a refresh nobody asked for respects the network preference")
    func pollingNotAllowed() {
        #expect(shouldRefresh(allowsAutomaticPolling: false) == false)
    }

    /// The first load is the ordinary one, and a failed one has Try again.
    @Test("a board that has loaded nothing yet is not refreshed")
    func neverLoaded() {
        #expect(shouldRefresh(secondsSinceLoad: nil) == false)
    }

    @Test("a clock that went backwards refreshes rather than freezing the list")
    func backwardsClock() {
        #expect(shouldRefresh(secondsSinceLoad: -500))
    }
}
