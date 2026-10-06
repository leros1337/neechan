import Foundation
import NeechanAPI
import Testing
@testable import NeechanUI

/// The length a video thumbnail carries in its corner.
///
/// Minutes and seconds, the way the player's own clock reads, so the corner of
/// a thumbnail and the end of the scrubber say the same thing about one clip.
@Suite("A video's length on its thumbnail")
struct VideoDurationLabelTests {
    /// Built from what a board answers with, so the field under test is the
    /// one the app decodes.
    private func attachment(type: Int, name: String, durationSeconds: Int?) throws -> NeechanAPI.Attachment {
        let duration = durationSeconds.map { #", "duration_secs": \#($0)"# } ?? ""
        let json = """
        {"path": "/b/src/1/\(name)", "thumbnail": "/b/thumb/1/s.jpg", \
        "name": "\(name)", "type": \(type)\(duration)}
        """
        return try JSONDecoder().decode(NeechanAPI.Attachment.self, from: Data(json.utf8))
    }

    @Test("under a minute reads as nought minutes")
    func underAMinute() throws {
        let clip = try attachment(type: 6, name: "1.webm", durationSeconds: 42)
        #expect(clip.durationLabel == "0:42")
    }

    @Test("seconds are padded, minutes are not")
    func overAMinute() throws {
        let clip = try attachment(type: 10, name: "1.mp4", durationSeconds: 83)
        #expect(clip.durationLabel == "1:23")
    }

    /// Asked for as minutes and seconds, and an hour-long clip is rare enough
    /// on a board that sixty-odd minutes reads better than a third field.
    @Test("past an hour the minutes keep counting")
    func overAnHour() {
        #expect(VideoDuration.label(seconds: 3725) == "62:05")
    }

    /// 4chan never sends a length, and a 2ch post sometimes goes without.
    @Test("a clip with no length says nothing")
    func missingLength() throws {
        let clip = try attachment(type: 6, name: "1.webm", durationSeconds: nil)
        #expect(clip.durationLabel == nil)
    }

    @Test("a length of nothing is no length")
    func zeroLength() throws {
        let clip = try attachment(type: 6, name: "1.webm", durationSeconds: 0)
        #expect(clip.durationLabel == nil)
    }

    @Test("a picture has no length")
    func picture() throws {
        let picture = try attachment(type: 2, name: "1.png", durationSeconds: 42)
        #expect(picture.durationLabel == nil)
    }
}
