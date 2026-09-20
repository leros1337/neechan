import Foundation
import Libavformat
import Libavutil
import Synchronization

/// Feeds the demuxer from the network, a piece at a time.
///
/// FFmpeg would happily open a URL with its own HTTP client, which 2ch
/// refuses: it carries neither the browser-check cookie nor Apple's TLS. This
/// hands the demuxer a source it reads like a file instead, while the bytes
/// underneath arrive on `URLSession` with the app's own headers. Playback
/// still starts as soon as the header and the first frames have landed rather
/// than after the whole clip.
///
/// Every call here comes from the demuxing thread and is expected to block,
/// exactly as reading a file would block.
final class RangeReaderIO: @unchecked Sendable {
    private let reader: MediaRangeReader
    /// Where the demuxer has read up to. Its own, not the reader's: the reader
    /// is told an offset on every call and keeps no position of its own.
    private let offset = Mutex<Int64>(0)
    private var allocated: UnsafeMutablePointer<AVIOContext>?

    /// Asked before every attempt at a read, and again before waiting to try
    /// again.
    ///
    /// Without it a reader that has been given up on carries on retrying: a
    /// feed that swipes to the next clip left the last one's reads running for
    /// half a minute, holding connections the clip now on screen needed. The
    /// same goes for a seek, which cannot be answered while the read it
    /// replaced is still being retried.
    var shouldStopReading: (@Sendable () -> Bool)?

    /// The context to hand to `AVFormatContext.pb`.
    var context: UnsafeMutablePointer<AVIOContext>? { allocated }

    /// - Parameter bufferSize: bigger than FFmpeg's 32 KB default, because
    ///   every read crosses into the app's own networking and the demuxer asks
    ///   constantly while it works out what the file is.
    init(reader: MediaRangeReader, bufferSize: Int = 256 << 10) {
        self.reader = reader

        // FFmpeg takes this buffer over and may reallocate it, so it has to
        // come from av_malloc rather than from Swift.
        let buffer = av_malloc(bufferSize)?.assumingMemoryBound(to: UInt8.self)
        allocated = avio_alloc_context(
            buffer,
            Int32(bufferSize),
            0,
            Unmanaged.passUnretained(self).toOpaque(),
            ffmpegRead,
            nil,
            ffmpegSeek
        )

        // A source whose length is unknown cannot be scrubbed, and saying so
        // stops the demuxer seeking to the end to look for an index.
        allocated?.pointee.seekable = reader.length() != nil ? FFmpegStatus.seekableNormal : 0
    }

    deinit {
        close()
    }

    /// Gives up whatever request is waiting, so a read stuck on the network
    /// comes back at once rather than when the server answers.
    func abandonInFlightRequest() {
        reader.abandonInFlightRequest()
    }

    /// Gives the context and its buffer back.
    ///
    /// Has to be done by hand: closing a format context does not free a custom
    /// source, and the buffer FFmpeg ended up with is not always the one it
    /// was given.
    func close() {
        guard let owned = allocated else { return }
        allocated = nil
        // The buffer FFmpeg ends up with is not always the one it was given,
        // so it is read back off the context rather than remembered.
        av_freep(&owned.pointee.buffer)
        var context: UnsafeMutablePointer<AVIOContext>? = owned
        avio_context_free(&context)
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let start = offset.withLock { $0 }

        // A read that fails is not a read that finished. The reader answers 0
        // at the end of the file and a negative number when it could not
        // reach the bytes, and conflating the two ends the clip on the first
        // hiccup: the demuxer stops, the queues drain, and the player reports
        // that the file simply ended. A few retries cover a dropped
        // connection; past that the failure is passed on as a failure.
        for attempt in 0...Self.retries {
            if shouldStopReading?() == true || reader.wasGivenUp {
                MediaLog.reader.debug("given up on before reading at \(start, privacy: .public)")
                return FFmpegStatus.inputOutputError
            }

            let copied = reader.read(into: buffer, at: start, count: Int(size))
            if copied > 0 {
                offset.withLock { $0 += Int64(copied) }
                return Int32(copied)
            }
            if copied == 0 {
                MediaLog.reader.debug("end of file at \(start, privacy: .public)")
                return FFmpegStatus.endOfFile
            }
            MediaLog.reader.error(
                """
                read failed at \(start, privacy: .public)                 for \(size, privacy: .public) bytes,                 attempt \(attempt + 1, privacy: .public) of \(Self.retries + 1, privacy: .public)
                """
            )

            // A connection that has just dropped refuses the next request in
            // no time at all, which without this spends every attempt inside a
            // second and gives up exactly as the network is coming back. Each
            // wait is longer than the last.
            guard attempt < Self.retries, shouldStopReading?() != true, !reader.wasGivenUp else { break }
            Thread.sleep(forTimeInterval: Self.pause(beforeAttempt: attempt + 1))
        }
        return FFmpegStatus.inputOutputError
    }

    /// How many times a failed read is tried again before giving up.
    ///
    /// Read from the demuxing thread, which is expected to block, so waiting
    /// here holds up nothing that was not already waiting.
    private static let retries = 3

    /// How long to wait before trying again: a quarter of a second, then half,
    /// then a whole one. Long enough for a reconnection, short enough that a
    /// clip which can be recovered is recovered before the reader gives up on
    /// it themselves.
    static func pause(beforeAttempt attempt: Int) -> TimeInterval {
        min(1, 0.25 * pow(2, Double(attempt - 1)))
    }

    fileprivate func seek(to target: Int64, whence: Int32) -> Int64 {
        // Not a seek at all: the demuxer asking how long the file is, which it
        // wants before it will let anyone scrub.
        if whence & FFmpegStatus.seekSize != 0 {
            return reader.length() ?? -1
        }

        let resolved: Int64
        switch whence {
        case Int32(SEEK_SET):
            resolved = target
        case Int32(SEEK_CUR):
            resolved = offset.withLock { $0 } + target
        case Int32(SEEK_END):
            guard let total = reader.length() else { return -1 }
            resolved = total + target
        default:
            return -1
        }

        guard resolved >= 0 else { return -1 }
        offset.withLock { $0 = resolved }
        return resolved
    }
}

// FFmpeg calls back into C function pointers, which cannot capture anything,
// so the object is recovered from the opaque pointer it was handed.

private let ffmpegRead: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
) -> Int32 = { opaque, buffer, size in
    guard let opaque, let buffer, size > 0 else { return FFmpegStatus.endOfFile }
    return Unmanaged<RangeReaderIO>.fromOpaque(opaque).takeUnretainedValue()
        .read(into: buffer, size: size)
}

private let ffmpegSeek: @convention(c) (
    UnsafeMutableRawPointer?, Int64, Int32
) -> Int64 = { opaque, target, whence in
    guard let opaque else { return -1 }
    return Unmanaged<RangeReaderIO>.fromOpaque(opaque).takeUnretainedValue()
        .seek(to: target, whence: whence)
}
