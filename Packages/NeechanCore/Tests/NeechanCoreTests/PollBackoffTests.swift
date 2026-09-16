import Foundation
import Testing
@testable import NeechanCore

@Suite("Poll backoff")
struct PollBackoffTests {
    private let base = Duration.seconds(60)
    private let cap = Duration.seconds(900)

    @Test("a thread that has just been quiet once is still polled at the reader's interval")
    func graceBeforeBackingOff() {
        #expect(PollBackoff.interval(base: base, quiet: 0, cap: cap) == base)
        #expect(PollBackoff.interval(base: base, quiet: 1, cap: cap) == base)
    }

    @Test("each further quiet poll doubles the wait")
    func doubling() {
        #expect(PollBackoff.interval(base: base, quiet: 2, cap: cap) == .seconds(120))
        #expect(PollBackoff.interval(base: base, quiet: 3, cap: cap) == .seconds(240))
        #expect(PollBackoff.interval(base: base, quiet: 4, cap: cap) == .seconds(480))
    }

    @Test("the wait never grows past the cap")
    func capped() {
        #expect(PollBackoff.interval(base: base, quiet: 5, cap: cap) == cap)
        #expect(PollBackoff.interval(base: base, quiet: 500, cap: cap) == cap)
    }

    @Test("low power doubles the wait, and the cap still holds")
    func lowPower() {
        #expect(PollBackoff.interval(base: base, quiet: 0, cap: cap, lowPower: true) == .seconds(120))
        #expect(PollBackoff.interval(base: base, quiet: 3, cap: cap, lowPower: true) == .seconds(480))
        #expect(PollBackoff.interval(base: base, quiet: 9, cap: cap, lowPower: true) == cap)
    }

    @Test("news resets the wait to the reader's interval")
    func newsResets() {
        let backedOff = PollBackoff.interval(base: base, quiet: 6, cap: cap)
        #expect(backedOff > base)
        #expect(PollBackoff.interval(base: base, quiet: 0, cap: cap) == base)
    }

    @Test("an interval of nothing stays nothing")
    func zeroBase() {
        #expect(PollBackoff.interval(base: .zero, quiet: 4, cap: cap) == .zero)
    }
}
