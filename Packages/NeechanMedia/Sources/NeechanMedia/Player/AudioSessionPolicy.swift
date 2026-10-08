import Foundation

/// What one player's sound amounts to, as far as other apps are concerned.
enum SoundStatus: Equatable, Sendable {
    /// Playing out loud. It needs the sound to itself, so music from another
    /// app stops.
    case audible
    /// Not heard yet, but about to be: a clip with sound being opened to
    /// play, or one waiting for bytes. Not a reason to take the sound from
    /// another app, and not a reason to give it back either. Paging from one
    /// clip with sound to the next goes through here.
    case holding
    /// Nothing to hear: muted, stopped, or a file with no sound in it.
    case silent

    init(state: PlaybackState, isMuted: Bool, hasAudio: Bool?, autoplays: Bool, isLoaded: Bool) {
        guard isLoaded, !isMuted, hasAudio != false else {
            self = .silent
            return
        }
        switch state {
        // Playing before the file has said whether it holds any sound only
        // happens in the moment between asking and the file opening.
        case .playing: self = hasAudio == true ? .audible : .holding
        case .buffering: self = .holding
        case .preparing: self = autoplays ? .holding : .silent
        case .idle, .paused, .finished, .failed: self = .silent
        }
    }
}

/// When the app takes the sound from whatever else was playing, and when it
/// gives it back.
///
/// Kept apart from the audio session so the rules can be read, and tested,
/// without one. Nothing on the simulator plays music, so a rule that is wrong
/// here shows only on a phone, as Spotify stopping for a muted clip or staying
/// stopped after the gallery has closed.
///
/// Taking the sound stops other apps, which iOS calls interrupting them.
/// Giving it back tells them they may carry on. Music and Spotify do; a video
/// in another app's picture-in-picture window usually waits for a tap.
struct AudioSessionPolicy<Player: Hashable> {
    enum Action: Equatable {
        /// Take the sound for this app alone.
        case take
        /// Give it back once `token` comes round, unless something cancels it.
        case scheduleHandBack(Int)
        case cancelHandBack
        /// Give it back now, telling other apps they may carry on.
        case handBack
        /// Pause these players: another app has the sound now.
        case pause([Player])
    }

    /// Whether this app has the sound to itself.
    private(set) var isHeld = false
    private var statuses: [Player: SoundStatus] = [:]
    private var pendingHandBack: Int?
    private var lastToken = 0

    /// A player says what its sound amounts to now.
    @discardableResult
    mutating func report(_ player: Player, _ status: SoundStatus) -> [Action] {
        let previous = statuses.updateValue(status, forKey: player)
        var actions: [Action] = []

        if hasAudible {
            actions += cancelPendingHandBack()
            // Taken again whenever a player starts being heard, not only when
            // the sound is not already this app's. A clip paused for an
            // interruption comes back to a session nothing has re-activated,
            // and plays in silence.
            if previous != .audible || !isHeld {
                actions.append(.take)
                isHeld = true
            }
        } else if hasHolding {
            actions += cancelPendingHandBack()
        } else if isHeld, pendingHandBack == nil {
            // Not at once. The feed pauses as a drag begins and plays as it
            // settles, and handing the sound back in between made the other
            // app start and stop on every swipe.
            lastToken += 1
            pendingHandBack = lastToken
            actions.append(.scheduleHandBack(lastToken))
        }
        return actions
    }

    /// The moment given to a hand-back has passed.
    @discardableResult
    mutating func graceElapsed(_ token: Int) -> [Action] {
        guard pendingHandBack == token else { return [] }
        pendingHandBack = nil
        guard isHeld, !hasAudible, !hasHolding else { return [] }
        isHeld = false
        return [.handBack]
    }

    /// A player has stopped for good.
    ///
    /// Gives the sound back at once if no other player needs it: this is the
    /// gallery or the feed closing, and nothing is going to play next.
    @discardableResult
    mutating func playerGone(_ player: Player) -> [Action] {
        statuses[player] = nil
        guard !hasAudible, !hasHolding else { return [] }
        return handBackNow()
    }

    /// Gives the sound back at once, whatever the players say.
    ///
    /// For the app going to the background, where a hand-back left waiting
    /// may never come round.
    @discardableResult
    mutating func handBackNow() -> [Action] {
        let actions = cancelPendingHandBack()
        guard isHeld else { return actions }
        isHeld = false
        return actions + [.handBack]
    }

    /// Takes the sound again for a player that is being heard.
    @discardableResult
    mutating func reclaim() -> [Action] {
        guard hasAudible else { return [] }
        isHeld = true
        return cancelPendingHandBack() + [.take]
    }

    /// Another app has taken the sound: a phone call, or Spotify started from
    /// Control Centre.
    ///
    /// Whatever was using the sound is paused, and stays paused until the
    /// reader plays it again. Nothing is handed back, since nothing is this
    /// app's to give.
    @discardableResult
    mutating func interruptionBegan(becauseAppWasSuspended: Bool) -> [Action] {
        // Delivered late, as the app comes back, about a time it was not
        // running. The background has already given the sound back.
        guard !becauseAppWasSuspended else { return [] }
        isHeld = false
        var actions = cancelPendingHandBack()
        // A clip about to play is paused too: it would otherwise take the
        // sound straight back from the app the reader has just turned on.
        let using = statuses.filter { $0.value != .silent }.map(\.key)
        if !using.isEmpty { actions.append(.pause(using)) }
        return actions
    }

    private var hasAudible: Bool { statuses.values.contains(.audible) }
    private var hasHolding: Bool { statuses.values.contains(.holding) }

    private mutating func cancelPendingHandBack() -> [Action] {
        guard pendingHandBack != nil else { return [] }
        pendingHandBack = nil
        return [.cancelHandBack]
    }
}
