import Foundation
import Testing
@testable import NeechanMedia

@Suite("Animation frame rate")
struct AnimationFrameRateTests {
    @Test("a ten frames a second animation asks for ten hertz")
    func ordinaryGIF() {
        #expect(AnimationFrameRate.hertz(forMinimumDelay: 0.1) == 10)
    }

    @Test("a twenty frames a second animation asks for twenty hertz")
    func fasterGIF() {
        #expect(AnimationFrameRate.hertz(forMinimumDelay: 0.05) == 20)
    }

    /// Files exist whose frames claim a delay of nothing at all. They must not
    /// turn into a request for thousands of hertz.
    @Test("very short delays are capped at sixty hertz")
    func clampedAtTheTop() {
        #expect(AnimationFrameRate.hertz(forMinimumDelay: 0.001) == 60)
        #expect(AnimationFrameRate.hertz(forMinimumDelay: 0) == 60)
    }

    @Test("a slow animation still asks for ten hertz, so frames land on time")
    func flooredAtTheBottom() {
        #expect(AnimationFrameRate.hertz(forMinimumDelay: 2) == 10)
    }

    @Test("the range brackets the rate the animation needs")
    func range() {
        let range = AnimationFrameRate.range(forMinimumDelay: 0.1)
        #expect(range.preferred == 10)
        #expect(range.minimum == 10)
        #expect(range.maximum == 20)
        #expect(AnimationFrameRate.range(forMinimumDelay: 0.001).maximum == 60)
    }
}
