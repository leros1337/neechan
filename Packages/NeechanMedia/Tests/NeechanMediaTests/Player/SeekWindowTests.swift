import Foundation
import Testing
@testable import NeechanMedia

/// Which decoded picture counts as the one a seek was waiting for.
///
/// The rule that was missing: a picture left over from wherever the clip was
/// before the seek is not it. Only pictures before the target were being
/// rejected, so one from further along the file sailed through, satisfied the
/// seek, and the clock then started at the new position with nothing there to
/// show. On a phone that is a picture that freezes after a scrub.
@Suite("Which picture a seek is waiting for")
struct SeekWindowTests {
    @Test("the picture at the target is the one")
    func theTargetItself() {
        #expect(Pipeline.isForSeek(time: 6.0, target: 6.0))
        // A file is rewound to the keyframe before the target, so what is
        // waited for lands just after it rather than exactly on it.
        #expect(Pipeline.isForSeek(time: 6.03, target: 6.0))
        #expect(Pipeline.isForSeek(time: 6.9, target: 6.0))
    }

    @Test("pictures from before the target are still rejected")
    func beforeTheTarget() {
        #expect(!Pipeline.isForSeek(time: 5.9, target: 6.0))
        #expect(!Pipeline.isForSeek(time: 0, target: 6.0))
    }

    /// The regression: seeking back to four seconds and being handed a picture
    /// from twelve, which is where the clip had got to before.
    @Test("a picture left over from further along the clip is rejected")
    func leftOverFromElsewhere() {
        #expect(!Pipeline.isForSeek(time: 12.617, target: 4.011))
        #expect(!Pipeline.isForSeek(time: 35.0, target: 4.0))
    }

    /// Generous rather than exact: a sparse file can put the first decodable
    /// picture some way past where the reader pointed, and rejecting that
    /// would leave the seek waiting for something that never comes.
    @Test("a picture a little past the target is still accepted")
    func justPastTheTarget() {
        #expect(Pipeline.isForSeek(time: 6.0 + Pipeline.seekWindow - 0.1, target: 6.0))
        #expect(!Pipeline.isForSeek(time: 6.0 + Pipeline.seekWindow + 0.1, target: 6.0))
    }

    @Test("seeking to the very start accepts the first picture in the file")
    func theStartOfTheFile() {
        #expect(Pipeline.isForSeek(time: 0, target: 0))
        #expect(Pipeline.isForSeek(time: 0.033, target: 0))
    }
}
