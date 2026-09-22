import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// Who gets the connection when there is not enough of it.
///
/// A feed warms the clip after next while the current one plays. On a fast
/// connection that is free and hides the wait on a swipe. On a slow one it is
/// bandwidth taken from the picture the reader is looking at, to fetch one
/// they have not asked for, which is why a feed stuttered where the viewer
/// did not.
@Suite("Reading ahead gives way", .serialized)
struct PlaybackDemandTests {
    @Test("nothing is waiting to begin with")
    func quietToStart() {
        PlaybackDemand.setWaitingForBytes(false)
        #expect(!PlaybackDemand.isWaitingForBytes)
    }

    @Test("the player saying it is waiting is visible to the prefetcher")
    func waitingIsVisible() {
        PlaybackDemand.setWaitingForBytes(true)
        #expect(PlaybackDemand.isWaitingForBytes)
        PlaybackDemand.setWaitingForBytes(false)
        #expect(!PlaybackDemand.isWaitingForBytes)
    }

    @Test("whatever is being read ahead is given up the moment playback waits")
    func readingAheadIsGivenUp() async {
        PlaybackDemand.setWaitingForBytes(false)

        let gaveWay = Mutex(false)
        PlaybackDemand.whenPlaybackStartsWaiting { gaveWay.withLock { $0 = true } }
        defer { PlaybackDemand.whenPlaybackStartsWaiting {} }

        PlaybackDemand.setWaitingForBytes(true)
        #expect(gaveWay.withLock { $0 }, "reading ahead carried on while the picture waited")

        // Only on the change, not on every report: the player says where it is
        // ten times a second, and giving up again each time would cancel a
        // warm that had just been allowed to start.
        gaveWay.withLock { $0 = false }
        PlaybackDemand.setWaitingForBytes(true)
        #expect(!gaveWay.withLock { $0 }, "it was given up twice for one wait")

        PlaybackDemand.setWaitingForBytes(false)
    }
}
