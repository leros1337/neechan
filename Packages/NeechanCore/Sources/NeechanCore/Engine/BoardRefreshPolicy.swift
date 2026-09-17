import Foundation

/// Whether a board the reader has come back to is worth fetching again.
///
/// A value on its own, beside `PollBackoff` and `PollConditions`, because this
/// is the whole of the decision and the rest is plumbing: a board screen that
/// asks this on the way back in needs no rule of its own.
public enum BoardRefreshPolicy {
    /// - Parameters:
    ///   - lastLoadedAt: when the list on screen arrived, or nil when nothing
    ///     has arrived yet.
    ///   - staleAfter: how old a list may be before it is worth replacing.
    ///   - isNearTop: whether the reader is at the top of the list. A board is
    ///     ordered by what was last bumped, so a refresh moves rows: doing that
    ///     under somebody part way down it takes away the thing they were
    ///     reading towards.
    ///   - isLoading: whether a fetch is already on its way.
    ///   - allowsAutomaticPolling: the reader's Wi-Fi-only preference and the
    ///     state of the network. This refresh is one nobody asked for, so it is
    ///     held back by both; pulling to refresh is not.
    public static func shouldRefresh(
        lastLoadedAt: Date?,
        now: Date = .now,
        staleAfter: Duration,
        isNearTop: Bool,
        isLoading: Bool,
        allowsAutomaticPolling: Bool
    ) -> Bool {
        guard allowsAutomaticPolling, isNearTop, !isLoading else { return false }
        // Nothing has been loaded yet, so the ordinary first load is what this
        // board needs, and a failure has its own way back.
        guard let lastLoadedAt else { return false }

        let age = now.timeIntervalSince(lastLoadedAt)
        // A clock that moved backwards says nothing about how old the list is.
        // Refreshing then is the cheaper mistake: the other way round leaves a
        // list that can never look stale again.
        guard age >= 0 else { return true }
        return age >= staleAfter.seconds
    }
}
