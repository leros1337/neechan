import Foundation
import Testing
@testable import NeechanCore

@Suite("Watcher schedule")
struct WatcherScheduleTests {
    private let schedule = WatcherSchedule(baseInterval: .seconds(60), maxInterval: .seconds(900))
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let a = ThreadKey(site: .dvach, board: "b", threadNum: 1)
    private let b = ThreadKey(site: .dvach, board: "b", threadNum: 2)

    private func state(
        polledSecondsAgo seconds: TimeInterval,
        quiet: Int = 0,
        closed: Bool = false,
        deleted: Bool = false
    ) -> WatcherSchedule.ThreadState {
        WatcherSchedule.ThreadState(
            lastPolledAt: now.addingTimeInterval(-seconds),
            quietPolls: quiet,
            isClosed: closed,
            isDeleted: deleted
        )
    }

    @Test("a thread never asked about is due at once")
    func unknownThreadsAreDue() {
        #expect(schedule.due([a], states: [:], at: now) == [a])
    }

    @Test("a thread asked about inside its interval is left alone")
    func recentThreadsAreNotDue() {
        #expect(schedule.due([a], states: [a: state(polledSecondsAgo: 30)], at: now).isEmpty)
        #expect(schedule.due([a], states: [a: state(polledSecondsAgo: 61)], at: now) == [a])
    }

    @Test("a thread the site has stopped serving is never due again")
    func deletedThreadsAreNeverDue() {
        let states = [a: state(polledSecondsAgo: 100_000, deleted: true)]
        #expect(schedule.due([a], states: states, at: now).isEmpty)
        #expect(schedule.interval(for: states[a]!) == nil)
        #expect(schedule.nextWake([a], states: states, at: now) == nil)
    }

    @Test("a closed thread waits for the longest interval, not the reader's")
    func closedThreadsWaitForTheCap() {
        let states = [a: state(polledSecondsAgo: 840, closed: true)]
        #expect(schedule.due([a], states: states, at: now).isEmpty, "fourteen minutes is not enough")

        let older = [a: state(polledSecondsAgo: 960, closed: true)]
        #expect(schedule.due([a], states: older, at: now) == [a], "sixteen minutes is")
    }

    @Test("quiet threads are asked about progressively less often")
    func quietThreadsBackOff() {
        #expect(schedule.interval(for: state(polledSecondsAgo: 0, quiet: 0)) == .seconds(60))
        #expect(schedule.interval(for: state(polledSecondsAgo: 0, quiet: 3)) == .seconds(240))
        #expect(schedule.interval(for: state(polledSecondsAgo: 0, quiet: 99)) == .seconds(900))
    }

    @Test("whatever has waited longest is asked about first")
    func oldestFirst() {
        let states = [
            a: state(polledSecondsAgo: 100),
            b: state(polledSecondsAgo: 500),
        ]
        #expect(schedule.due([a, b], states: states, at: now) == [b, a])
    }

    @Test("the next wake-up is the soonest thread's")
    func nextWakeIsTheSoonest() {
        let states = [
            a: state(polledSecondsAgo: 30),
            b: state(polledSecondsAgo: 50),
        ]
        let wake = schedule.nextWake([a, b], states: states, at: now)
        #expect(wake == now.addingTimeInterval(10), "the one polled fifty seconds ago is due first")
    }

    @Test("there is no next wake-up when every thread is gone")
    func nextWakeIsNilWhenNothingIsSchedulable() {
        let states = [a: state(polledSecondsAgo: 10, deleted: true)]
        #expect(schedule.nextWake([a], states: states, at: now) == nil)
    }

    @Test("news puts a thread back on the reader's interval")
    func newsResetsTheBackoff() {
        let backedOff = state(polledSecondsAgo: 0, quiet: 6)
        let after = schedule.afterPoll(backedOff, outcome: .news, at: now)

        #expect(after.quietPolls == 0)
        #expect(schedule.interval(for: after) == .seconds(60))
        #expect(after.lastPolledAt == now)
    }

    @Test("a quiet poll and a failed one both slow the thread down")
    func quietAndFailureBackOff() {
        #expect(schedule.afterPoll(state(polledSecondsAgo: 0), outcome: .quiet, at: now).quietPolls == 1)
        #expect(schedule.afterPoll(state(polledSecondsAgo: 0), outcome: .failure, at: now).quietPolls == 1)
    }

    /// Being told to slow down and then backing off one step at a time is how a
    /// client gets itself blocked.
    @Test("being rate limited goes straight to the longest wait")
    func rateLimitJumpsToTheCap() {
        let after = schedule.afterPoll(state(polledSecondsAgo: 0), outcome: .rateLimited, at: now)
        #expect(schedule.interval(for: after) == .seconds(900))
    }

    @Test("a poll that found the thread gone marks it so")
    func deletionIsRecorded() {
        let after = schedule.afterPoll(state(polledSecondsAgo: 0), outcome: .deleted, at: now)
        #expect(after.isDeleted)
        #expect(schedule.interval(for: after) == nil)
    }

    @Test("low power stretches the waits but not past the cap")
    func lowPower() {
        #expect(schedule.interval(for: state(polledSecondsAgo: 0), lowPower: true) == .seconds(120))
        #expect(schedule.interval(for: state(polledSecondsAgo: 0, quiet: 9), lowPower: true) == .seconds(900))
    }

    /// What the schedule is for, stated as a number: a thread nobody posts in
    /// is asked about a handful of times an hour instead of sixty.
    @Test("an hour of silence costs a handful of requests, not sixty")
    func anHourOfSilence() {
        var state = WatcherSchedule.ThreadState(lastPolledAt: now)
        var clock = now
        var polls = 0
        let hourEnd = now.addingTimeInterval(3600)

        while let next = schedule.nextPoll(for: state), next <= hourEnd {
            clock = next
            polls += 1
            state = schedule.afterPoll(state, outcome: .quiet, at: clock)
        }

        #expect(polls <= 10, "sixty at the reader's interval, \(polls) with the backoff")
        #expect(polls >= 5, "and not so few that news waits half an hour to be noticed")
    }

    /// The backoff must not cost responsiveness in a thread being written in.
    @Test("a busy thread is always asked about at the reader's interval")
    func aBusyThreadStaysFast() {
        var state = WatcherSchedule.ThreadState(lastPolledAt: now)
        var clock = now
        var polls = 0
        let hourEnd = now.addingTimeInterval(3600)

        while let next = schedule.nextPoll(for: state), next <= hourEnd {
            clock = next
            polls += 1
            state = schedule.afterPoll(state, outcome: .news, at: clock)
        }

        #expect(polls == 60, "one a minute, exactly as the reader asked")
    }
}
