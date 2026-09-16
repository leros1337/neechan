#if canImport(UIKit)
import SwiftUI
import UIKit

/// An image the reader can pinch and double-tap to zoom.
///
/// Built on `UIScrollView` rather than SwiftUI gestures: it gets momentum,
/// bounce, correct centring while zoomed out and the standard double-tap
/// behaviour for free, all of which a hand-rolled gesture stack gets subtly
/// wrong.
public struct ZoomableImageView: UIViewRepresentable {
    private let image: UIImage
    /// How far past fitting the screen the reader may zoom.
    private let maximumZoomFactor: CGFloat
    /// Called on a single tap, so the gallery can toggle its chrome.
    private let onSingleTap: (() -> Void)?

    public init(
        image: UIImage,
        maximumZoomFactor: CGFloat = 6,
        onSingleTap: (() -> Void)? = nil
    ) {
        self.image = image
        self.maximumZoomFactor = maximumZoomFactor
        self.onSingleTap = onSingleTap
    }

    public func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.maximumZoomFactor = maximumZoomFactor
        view.onSingleTap = onSingleTap
        view.display(image)
        return view
    }

    public func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        view.display(image)
    }
}

/// The scroll view behind `ZoomableImageView`.
///
/// All the sizing happens in `layoutSubviews`, because that is the first moment
/// the real bounds are known. An earlier version computed it when SwiftUI made
/// the view, when the bounds were still zero, so the image opened at its full
/// pixel size and only snapped to fit once a double tap forced a relayout.
public final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    /// Cleared once the image has been sized to the screen for the first time.
    private var needsInitialZoom = true
    private var lastLaidOutBounds: CGSize = .zero

    public var maximumZoomFactor: CGFloat = 6
    public var onSingleTap: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        decelerationRate = .fast

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        // Without this the single tap fires before the second tap can arrive.
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    /// Shows an image, resetting the zoom when it is a different one.
    public func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        // The frame is the image's own size; the scroll view's zoom scale is
        // what makes it fit, which is how UIScrollView expects to be driven.
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        needsInitialZoom = true
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard imageView.image != nil, bounds.width > 0, bounds.height > 0 else { return }

        let boundsChanged = bounds.size != lastLaidOutBounds
        lastLaidOutBounds = bounds.size

        if needsInitialZoom || boundsChanged {
            updateZoomScales(resetToFit: needsInitialZoom)
            needsInitialZoom = false
        }
        centerImage()
    }

    /// Recomputes the scale that fits the image, and how far past it the reader
    /// may zoom.
    private func updateZoomScales(resetToFit: Bool) {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            return
        }
        let fitScale = min(
            bounds.width / image.size.width,
            bounds.height / image.size.height
        )
        minimumZoomScale = fitScale
        // Always leave room to zoom in, even for an image larger than the screen.
        maximumZoomScale = max(fitScale * maximumZoomFactor, 1)

        if resetToFit || zoomScale < fitScale {
            zoomScale = fitScale
        }
    }

    /// Keeps the image centred while it is smaller than the viewport.
    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical, right: horizontal
        )
    }

    // MARK: Gestures

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // Zoom to where the reader tapped, not to the middle.
        let target = min(maximumZoomScale, minimumZoomScale * 3)
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(
            to: CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            animated: true
        )
    }

    // MARK: UIScrollViewDelegate

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }
}
#endif
