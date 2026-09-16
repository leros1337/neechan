import Foundation
import Testing
@testable import NeechanUI

@Suite("Pull up to refresh")
struct PullUpProgressTests {
    @Test("at rest nothing is shown and nothing would happen")
    func atRest() {
        let progress = PullUpProgress()

        #expect(progress.fraction == 0)
        #expect(progress.isArmed == false)
        #expect(progress.isVisible == false)
    }

    /// Flicking to the end rubber-bands by a few points; an indicator flashing
    /// up every time would be noise.
    @Test("a few points of rubber-banding neither shows nor fires anything")
    func smallOverscrollIsIgnored() {
        var progress = PullUpProgress()

        #expect(progress.update(overscroll: 5) == false)
        #expect(progress.isVisible == false)
        #expect(progress.isArmed == false)
        #expect(progress.update(overscroll: 0) == false, "a flick to the end is not a refresh")
    }

    /// The scroll view reports geometry on every frame, and the modifier stores
    /// the progress in `@State`. A store of an unchanged value still invalidates
    /// the view, so an unchanged reading has to leave the value equal for the
    /// caller's equality guard to have anything to compare.
    @Test("an unchanged reading leaves the value equal")
    func steadyReadingsCompareEqual() {
        var progress = PullUpProgress()
        let resting = PullUpReading(overscroll: -100, contentHeight: 1000, isScrollable: true)

        _ = progress.update(resting)
        let afterFirst = progress
        _ = progress.update(resting)

        #expect(progress == afterFirst)
    }

    @Test("a changed reading is not equal to the one before it")
    func changedReadingsDiffer() {
        var progress = PullUpProgress(threshold: 100)
        let settled = PullUpReading(overscroll: 0, contentHeight: 1000, isScrollable: true)

        _ = progress.update(settled)
        _ = progress.update(settled)
        let atRest = progress
        _ = progress.update(
            PullUpReading(overscroll: 40, contentHeight: 1000, isScrollable: true)
        )

        #expect(progress != atRest)
    }

    @Test("the indicator grows with the drag")
    func fractionGrows() {
        var progress = PullUpProgress(threshold: 100)

        #expect(progress.update(overscroll: 25) == false)
        #expect(progress.fraction == 0.25)
        #expect(progress.isVisible)
        #expect(progress.isArmed == false)

        #expect(progress.update(overscroll: 75) == false)
        #expect(progress.fraction == 0.75)
        #expect(progress.isArmed == false)
    }

    @Test("dragging past the threshold arms the refresh and stops growing")
    func armsAtThreshold() {
        var progress = PullUpProgress(threshold: 100)

        #expect(progress.update(overscroll: 100) == false, "still held, nothing fires yet")
        #expect(progress.isArmed)
        #expect(progress.fraction == 1)

        #expect(progress.update(overscroll: 400) == false)
        #expect(progress.isArmed)
        #expect(progress.fraction == 1, "the indicator does not keep growing")
    }

    /// Scrolling up inside the thread reports a negative overscroll, which is
    /// not a pull at all.
    @Test("scrolling away from the end is not a pull")
    func negativeOverscrollIsNothing() {
        var progress = PullUpProgress()
        #expect(progress.update(overscroll: -300) == false)

        #expect(progress.fraction == 0)
        #expect(progress.isVisible == false)
    }

    @Test("releasing an armed pull refreshes as the content springs back")
    func springBackFires() {
        var progress = PullUpProgress(threshold: 100)

        #expect(progress.update(overscroll: 120) == false, "armed, still held")
        #expect(progress.update(overscroll: 80) == false, "barely moved, still held")
        #expect(progress.update(overscroll: 20) == true, "sprang back: this is the release")
        #expect(progress.isArmed == false)
        #expect(progress.update(overscroll: 0) == false, "settling does not fire a second time")
    }

    @Test("a pull that never reached the threshold fires nothing on release")
    func shortPullDoesNothing() {
        var progress = PullUpProgress(threshold: 100)

        #expect(progress.update(overscroll: 60) == false)
        #expect(progress.update(overscroll: 20) == false)
        #expect(progress.update(overscroll: 0) == false)
    }

    @Test("two pulls in a row both fire")
    func repeatedPulls() {
        var progress = PullUpProgress(threshold: 100)

        #expect(progress.update(overscroll: 150) == false)
        #expect(progress.update(overscroll: 0) == true)
        #expect(progress.update(overscroll: 150) == false)
        #expect(progress.update(overscroll: 0) == true)
    }

    // MARK: Layout, which is not a gesture

    /// The thread used to refresh itself the moment it opened, and say "No new
    /// posts" over a thread the reader had only just arrived at.
    @Test("a thread shorter than the screen cannot be pulled")
    func shortContentNeverArms() {
        var progress = PullUpProgress(threshold: 72)

        // What an opening thread reports: a screenful of container, almost no
        // content, and therefore an overscroll of about a screen height.
        let opening = PullUpReading(overscroll: 780, contentHeight: 20, isScrollable: false)
        #expect(progress.update(opening) == false)
        #expect(progress.isArmed == false)
        #expect(progress.isVisible == false)

        // And the collapse as the posts arrive must not read as a release.
        #expect(progress.update(
            PullUpReading(overscroll: 0, contentHeight: 4000, isScrollable: true)
        ) == false)
    }

    @Test("content changing height disarms whatever was in progress")
    func relayoutDisarms() {
        var progress = PullUpProgress(threshold: 72)

        // The first reading at a new height is only the baseline: a pull is a
        // change against a settled layout, not against nothing.
        #expect(progress.update(
            PullUpReading(overscroll: 0, contentHeight: 4000, isScrollable: true)
        ) == false)
        #expect(progress.update(
            PullUpReading(overscroll: 100, contentHeight: 4000, isScrollable: true)
        ) == false)
        #expect(progress.isArmed)

        // More posts arrive: the end of the list moves under the reader.
        #expect(progress.update(
            PullUpReading(overscroll: 0, contentHeight: 5000, isScrollable: true)
        ) == false, "a relayout is not a release")
        #expect(progress.isArmed == false)
    }

    @Test("a real pull still fires once the height has settled")
    func genuinePullStillFires() {
        var progress = PullUpProgress(threshold: 72)
        let height: CGFloat = 4000

        #expect(progress.update(
            PullUpReading(overscroll: 0, contentHeight: height, isScrollable: true)
        ) == false)
        #expect(progress.update(
            PullUpReading(overscroll: 100, contentHeight: height, isScrollable: true)
        ) == false)
        #expect(progress.update(
            PullUpReading(overscroll: 10, contentHeight: height, isScrollable: true)
        ) == true)
    }

    @Test("resetting clears it, so the next pull starts from nothing")
    func resetClears() {
        var progress = PullUpProgress(threshold: 50)
        _ = progress.update(overscroll: 90)
        #expect(progress.isArmed)

        progress.reset()
        #expect(progress.isArmed == false)
        #expect(progress.fraction == 0)
    }
}
