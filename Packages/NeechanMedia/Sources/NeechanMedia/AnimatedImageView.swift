#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

/// Draws an animated image with its real per-frame timing.
///
/// `UIImage.animatedImage(with:duration:)` spreads one duration across every
/// frame, which visibly distorts GIFs whose frames have different delays, and
/// almost all of them do. A display link stepping through the decoded frames
/// costs little and plays them as authored.
public struct AnimatedImageView: UIViewRepresentable {
    private let animation: AnimatedImageDecoder.Animation
    private let isPaused: Bool

    public init(animation: AnimatedImageDecoder.Animation, isPaused: Bool = false) {
        self.animation = animation
        self.isPaused = isPaused
    }

    public func makeUIView(context: Context) -> AnimatedImageUIView {
        let view = AnimatedImageUIView()
        view.contentMode = .scaleAspectFit
        view.set(animation)
        return view
    }

    public func updateUIView(_ view: AnimatedImageUIView, context: Context) {
        view.set(animation)
        view.isPaused = isPaused
    }

    public static func dismantleUIView(_ view: AnimatedImageUIView, coordinator: ()) {
        view.stop()
    }
}

/// The view behind `AnimatedImageView`.
public final class AnimatedImageUIView: UIView {
    private var frames: [AnimatedImageDecoder.Frame] = []
    private var loopCount = 0
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var frameStartedAt: CFTimeInterval = 0
    private var completedLoops = 0

    public var isPaused = false {
        didSet { displayLink?.isPaused = isPaused }
    }

    public override class var layerClass: AnyClass { CALayer.self }

    public func set(_ animation: AnimatedImageDecoder.Animation) {
        guard frames.count != animation.frames.count || frames.isEmpty else { return }

        frames = animation.frames
        loopCount = animation.loopCount
        frameIndex = 0
        completedLoops = 0
        layer.contents = frames.first?.image
        layer.contentsGravity = .resizeAspect

        stop()
        guard animation.isAnimated else { return }
        start()
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        frameStartedAt = CACurrentMediaTime()
    }

    @objc private func step() {
        guard !frames.isEmpty else { return }
        let now = CACurrentMediaTime()
        let current = frames[frameIndex]
        guard now - frameStartedAt >= current.duration else { return }

        frameStartedAt = now
        frameIndex += 1
        if frameIndex >= frames.count {
            frameIndex = 0
            completedLoops += 1
            // A loop count of zero means repeat forever, which is what almost
            // every file on an imageboard asks for.
            if loopCount > 0, completedLoops >= loopCount {
                layer.contents = frames.last?.image
                stop()
                return
            }
        }
        layer.contents = frames[frameIndex].image
    }

    public override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
#endif
