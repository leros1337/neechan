import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

/// Pictures from a clip for the scrubber, from what is already on the device.
///
/// A reader and a decoder of its own, apart from the player's, on a queue of
/// its own: dragging the scrubber neither moves the clip being watched nor
/// competes with it for the connection, because nothing here goes to the
/// network at all. A part of the clip that has not arrived has no picture,
/// and the scrubber shows the post's own thumbnail there instead.
///
/// One picture per keyframe, the one at or before the position asked for:
/// that is what can be had without decoding every picture in between. Each is
/// kept, so dragging back over ground already covered decodes nothing.
public final class ScrubPreviewer: @unchecked Sendable {
    private let url: URL
    private let cache: MediaCache
    private let blocks: MediaBlockStore
    /// Handed to the reader, which in its cache-only mode never uses it.
    private let session: URLSession
    private let maxPixelSize: CGFloat
    private let queue = DispatchQueue(label: "io.neechan.media.scrub-preview", qos: .userInitiated)
    /// The newest request. One still waiting behind a newer one is not worth
    /// answering: the finger has moved on.
    private let latest = Mutex(0)

    // Touched only on `queue`.
    private var demuxer: Demuxer?
    private var decoder: VideoDecoder?
    /// The reader under the demuxer when the clip is read in pieces.
    private var reader: MediaRangeReader?
    /// Pictures made so far, by the keyframe they came from.
    private var pictures: [Int64: CGImage] = [:]
    private var isClosed = false

    /// Shared, and safe to use from any thread; making one is not cheap.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// - Parameters:
    ///   - url: the clip, as the player was given it. The block store and the
    ///     cache both know it by that address.
    ///   - maxPixelSize: the longest side of a picture.
    public init(
        url: URL,
        cache: MediaCache = .shared,
        blocks: MediaBlockStore = .shared,
        session: URLSession = .shared,
        maxPixelSize: CGFloat = 160
    ) {
        self.url = url
        self.cache = cache
        self.blocks = blocks
        self.session = session
        self.maxPixelSize = maxPixelSize
    }

    /// The picture at or before `time`, or nil when that part of the clip is
    /// not on the device, or a later request has taken its place.
    public func preview(at time: TimeInterval) async -> CGImage? {
        let ticket = latest.withLock { latest in
            latest += 1
            return latest
        }
        let wholeFile = await cache.cachedFile(for: url)
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed, latest.withLock({ $0 }) == ticket else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: picture(at: time, wholeFile: wholeFile))
            }
        }
    }

    /// How many pictures have been asked for, so a test can put two requests
    /// in a known order.
    var requestCount: Int { latest.withLock { $0 } }

    /// Lets go of the file and the decoder.
    public func close() {
        queue.async { [self] in
            isClosed = true
            decoder?.close()
            demuxer?.close()
            decoder = nil
            demuxer = nil
            reader = nil
            pictures.removeAll()
        }
    }

    private func picture(at time: TimeInterval, wholeFile: URL?) -> CGImage? {
        guard let (demuxer, decoder) = open(wholeFile: wholeFile),
              let stream = demuxer.videoStream
        else { return nil }
        // A read that failed on a missing block leaves FFmpeg's reader marked
        // as failed, and it stays that way until it is told otherwise.
        demuxer.resumeAfterSeek()
        _ = reader?.takeMiss()
        // A seek that missed went back to a keyframe it had already read, or
        // to the start, because the bytes where it should have landed are not
        // here. Its picture is of somewhere else.
        guard demuxer.seek(to: time), !demuxer.lastSeekMissed else { return nil }

        let index = stream.pointee.index
        // The first picture after a seek is the keyframe. A file where none
        // turns up within this many packets is not worth reading through.
        for _ in 0..<256 {
            guard let packet = demuxer.readPacket() else { return nil }
            guard packet.streamIndex == index else { continue }

            // The seek, or the read to this keyframe, ran into bytes that are
            // not here. A file whose index is not on the device is read
            // forward from wherever it can be, and comes to rest at the last
            // keyframe before the gap rather than the one asked for.
            if reader?.takeMiss() == true { return nil }

            let raw = packet.packet.pointee
            let key = raw.pts != Int64.min ? raw.pts : raw.dts
            if let made = pictures[key] { return made }

            var frame: DecodedFrame?
            decoder.flush()
            try? decoder.decode(packet, generation: 0) { frame = frame ?? $0 }
            // A decoder working on several pictures at once holds the first
            // back until it is told nothing more is coming.
            if frame == nil {
                try? decoder.decode(nil, generation: 0) { frame = frame ?? $0 }
            }
            decoder.flush()

            guard let frame, let made = image(from: frame.pixelBuffer, rotation: demuxer.rotationDegrees)
            else { return nil }
            if pictures.count >= 200 { pictures.removeAll() }
            pictures[key] = made
            return made
        }
        return nil
    }

    /// Opens the clip from the cache when it is there whole, and otherwise from
    /// whatever pieces of it the block store holds.
    private func open(wholeFile: URL?) -> (Demuxer, VideoDecoder)? {
        if let demuxer, let decoder { return (demuxer, decoder) }
        let source: MediaSource
        if let wholeFile {
            source = .file(wholeFile)
        } else {
            // Nothing of it has been read yet.
            guard blocks.length(for: url) != nil else { return nil }
            let reader = MediaRangeReader(url: url, session: session, store: blocks, isCacheOnly: true)
            self.reader = reader
            source = .remote(reader)
        }
        // Not remembered when it fails: the opening may simply not have
        // arrived yet, and the next request tries again.
        guard let opened = try? Demuxer(source: source),
              let stream = opened.videoStream,
              let decoder = try? VideoDecoder(stream: stream, capabilities: .current)
        else {
            reader = nil
            return nil
        }
        self.demuxer = opened
        self.decoder = decoder
        return (opened, decoder)
    }

    /// A small picture of `buffer`, turned the way the clip is shown.
    private func image(from buffer: CVPixelBuffer, rotation: Double) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if rotation != 0 {
            // The player turns its layer clockwise by this much; Core Image's
            // y-axis points up, which turns the other way.
            image = image.transformed(by: CGAffineTransform(rotationAngle: -rotation * .pi / 180))
            image = image.transformed(
                by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
            )
        }
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixelSize / longest)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGRect(
            x: image.extent.origin.x,
            y: image.extent.origin.y,
            width: max(1, floor(image.extent.width)),
            height: max(1, floor(image.extent.height))
        )
        return Self.context.createCGImage(image, from: size)
    }
}
