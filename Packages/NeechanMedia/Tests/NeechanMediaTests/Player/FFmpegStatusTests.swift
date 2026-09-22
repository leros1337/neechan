import CoreMedia
import Foundation
import Libavutil
import Testing
@testable import NeechanMedia

/// The numbers that stand in for FFmpeg's macros.
///
/// Each is written out in Swift because a C macro does not import. Each is
/// also checked against the library rather than against the comment beside it,
/// so a value that drifts in a future FFmpeg is caught here instead of showing
/// up as a clip that never ends.
@Suite("FFmpeg's sentinel values")
struct FFmpegStatusTests {
    @Test("end of file is the code the library reports")
    func endOfFileMatchesTheLibrary() {
        #expect(FFmpegStatus.message(FFmpegStatus.endOfFile) == "End of file")
    }

    @Test("try again is the code the decoder asks for more input with")
    func tryAgainMatchesTheLibrary() {
        // Spelled AVERROR(EAGAIN) in C, and EAGAIN is 35 on Darwin.
        #expect(FFmpegStatus.tryAgain == -Int32(EAGAIN))
        #expect(FFmpegStatus.message(FFmpegStatus.tryAgain) == "Resource temporarily unavailable")
    }

    @Test("no timestamp is the value FFmpeg leaves in an absent one")
    func noTimestampIsTheLibrarysOwn() {
        // AV_NOPTS_VALUE is INT64_MIN.
        #expect(FFmpegStatus.noTimestamp == Int64.min)
    }

    @Test("an unknown code still gives something to print")
    func unknownCodesStillDescribe() {
        #expect(!FFmpegStatus.message(-999_999).isEmpty)
    }
}
