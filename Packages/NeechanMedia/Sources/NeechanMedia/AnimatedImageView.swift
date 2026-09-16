#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

/// Draws an animated image with its real per-frame timing.
///
/// `UIImage.animatedImage(with:duration:)` spreads one duration across every
/// frame, which visibly distorts GIFs whose frames have different delays, and
/// almost all of them do. A display link stepping through the frames costs
/// little and plays them as authored.
public struct AnimatedImageView: UIViewRepresentable {
    private let decoder: AnimatedFrameDecoder
    private let metadata: AnimatedImageDecoder.Metadata
    private let isPaused: Bool

    public init(
        decoder: AnimatedFrameDecoder,
        metadata: AnimatedImageDecoder.Metadata,
        isPaused: Bool = false
    ) {
        self.decoder = decoder
        self.metadata = metadata
        self.isPaused = isPaused
    }

    public func makeUIView(context: Context) -> AnimatedImageUIView {
        let view = AnimatedImageUIView()
        view.contentMode = .scaleAspectFit
        view.set(decoder: decoder, metadata: metadata)
        view.isPaused = isPaused
        return view
    }

    public func updateUIView(_ view: AnimatedImageUIView, context: Context) {
        view.set(decoder: decoder, metadata: metadata)
        view.isPaused = isPaused
    }

    public static func dismantleUIView(_ view: AnimatedImageUIView, coordinator: ()) {
        view.stop()
    }
}

/// The view behind `AnimatedImageView`.
@MainActor
public final class AnimatedImageUIView: UIView {
    private var decoder: AnimatedFrameDecoder?
    private var metadata: AnimatedImageDecoder.Metadata?
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var frameStartedAt: CFTimeInterval = 0
    private var completedLoops = 0
    /// Frames already asked for, so a slow decode is not asked for twice.
    private var requested: Set<Int> = []
    /// Frames in hand, kept small: the decoder holds its own few, and this is
    /// only what the display link can reach without awaiting.
    private var ready: [Int: CGImage] = [:]

    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            displayLink?.isPaused = isPaused
            // Resuming starts the current frame's clock again rather than
            // counting the time spent paused against it, which would otherwise
            // skip straight past a frame on the way back.
            if !isPaused { frameStartedAt = CACurrentMediaTime() }
        }
    }

    public override class var layerClass: AnyClass { CALayer.self }

    public func set(
        decoder: AnimatedFrameDecoder,
        metadata: AnimatedImageDecoder.Metadata
    ) {
        guard self.decoder !== decoder else { return }

        self.decoder = decoder
        self.metadata = metadata
        frameIndex = 0
        completedLoops = 0
        requested = []
        ready = [:]
        layer.contentsGravity = .resizeAspect

        stop()
        // The first frame is drawn as soon as it arrives; the rest follow the
        // display link.
        request(0)
        guard metadata.isAnimated else { return }
        start()
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func start() {
        guard let metadata else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        // Asks for the rate the animation actually runs at. Without this the
        // link wakes on every vsync — 120 times a second on a ProMotion screen
        // — and almost every one of those wakeups has nothing to draw.
        link.preferredFrameRateRange = AnimationFrameRate.range(
            forMinimumDelay: metadata.shortestFrameDuration
        )
        link.add(to: .main, forMode: .common)
        link.isPaused = isPaused
        displayLink = link
        frameStartedAt = CACurrentMediaTime()
        request(1)
    }

    /// Decodes a frame in the background and keeps it for the display link.
    private func request(_ index: Int) {
        guard let decoder, let metadata, metadata.frameCount > 0 else { return }
        let wrapped = index % metadata.frameCount
        guard ready[wrapped] == nil, requested.insert(wrapped).inserted else { return }

        Task { [weak self] in
            let image = await decoder.frame(at: wrapped)
            guard let self, let image else { return }
            ready[wrapped] = image
            // Keep only what the loop is about to need.
            if ready.count > 4 {
                let keep = Set([frameIndex, (frameIndex + 1) % metadata.frameCount])
                ready = ready.filter { keep.contains($0.key) || $0.key == wrapped }
                requested = requested.intersection(ready.keys)
            }
            if layer.contents == nil, wrapped == frameIndex {
                layer.contents = image
            }
        }
    }

    @objc private func step() {
        guard let metadata, metadata.frameCount > 0 else { return }
        let now = CACurrentMediaTime()
        let duration = metadata.durations[min(frameIndex, metadata.durations.count - 1)]
        guard now - frameStartedAt >= duration else { return }

        let next = (frameIndex + 1) % metadata.frameCount
        // A frame that has not finished decoding is waited for rather than
        // skipped: an animation that drops frames under load looks broken, and
        // one held a moment longer does not.
        guard let image = ready[next] else {
            request(next)
            return
        }

        frameStartedAt = now
        frameIndex = next
        if next == 0 {
            completedLoops += 1
            // A loop count of zero means repeat forever, which is what almost
            // every file on an imageboard asks for.
            if metadata.loopCount > 0, completedLoops >= metadata.loopCount {
                stop()
                return
            }
        }
        layer.contents = image
        ready[next] = nil
        requested.remove(next)
        request(next + 1)
    }

    public override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
#endif
