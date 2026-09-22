import Foundation
import Libavutil

/// FFmpeg's sentinel values.
///
/// Every one of these is a macro in C, and a macro does not survive the trip
/// into Swift. They are written out here with the expression they come from
/// beside them, and the tests check each number against the library itself
/// rather than trusting the comment.
enum FFmpegStatus {
    /// `AVERROR_EOF`, which C spells `-MKTAG('E', 'O', 'F', ' ')`.
    ///
    /// Returned by a read that has reached the end of the file, and by a
    /// decoder that has been drained. Not a failure.
    static let endOfFile: Int32 = -541_478_725

    /// `AVERROR(EAGAIN)`: the decoder wants more input before it will hand
    /// anything back. Also not a failure.
    static let tryAgain: Int32 = -35

    /// `AVERROR(EIO)`: the bytes could not be reached. Distinct from the end
    /// of the file, which is not a failure at all.
    static let inputOutputError: Int32 = -5

    /// `AV_NOPTS_VALUE`: this packet or frame carries no timestamp.
    static let noTimestamp = Int64.min

    /// `AVSEEK_SIZE`: a seek callback being asked how long the file is, rather
    /// than to move within it.
    static let seekSize: Int32 = 0x1_0000

    /// `AVIO_SEEKABLE_NORMAL`: this source can seek anywhere in the file.
    static let seekableNormal: Int32 = 1

    /// `AVFMT_FLAG_CUSTOM_IO`: the bytes come from somewhere the app provides
    /// rather than from a URL FFmpeg opened itself.
    static let customIO: Int32 = 0x0080

    /// `AVSEEK_FLAG_BACKWARD`: land on or before the time asked for.
    ///
    /// Always what a seek wants: video can only be decoded from a keyframe, so
    /// the search starts at the one before the target and decodes forward.
    static let seekBackward: Int32 = 1

    /// What FFmpeg says about a code, in words.
    ///
    /// For diagnostics only. What the reader is shown never comes from here.
    static func message(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard av_strerror(code, &buffer, buffer.count) == 0 else {
            return "error \(code)"
        }
        let text = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: text, as: UTF8.self)
    }
}
