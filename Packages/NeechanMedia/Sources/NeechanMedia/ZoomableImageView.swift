/// Whether the picture on screen has anything for Live Text, and whether the
/// reader has it highlighted.
///
/// Outside the UIKit block so the gallery, which also builds for macOS, can
/// hold one.
public struct LiveTextStatus: Equatable, Sendable {
    /// The picture holds text, a code, or something Visual Look Up knows.
    public var isAvailable = false
    /// The reader has asked to see it: the words are lifted out of the
    /// picture and can be selected.
    public var isHighlighted = false

    public init(isAvailable: Bool = false, isHighlighted: Bool = false) {
        self.isAvailable = isAvailable
        self.isHighlighted = isHighlighted
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(VisionKit)
import VisionKit
#endif

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
    /// Called when the image starts or stops being zoomed in.
    ///
    /// The viewer above this closes on a downward drag, which must not happen
    /// while the reader is dragging a magnified image around.
    private let onZoomChanged: ((Bool) -> Void)?
    /// Names the picture for Live Text, which looks for text in it only while
    /// this is set. Nil for a page that is not on screen: the gallery keeps its
    /// neighbours alive, and analysing them is work nobody sees.
    private let analysisKey: String?
    /// Whether the reader has asked to see the text in the picture.
    private let isLiveTextHighlighted: Bool
    private let onLiveTextChanged: ((LiveTextStatus) -> Void)?

    public init(
        image: UIImage,
        maximumZoomFactor: CGFloat = 6,
        analysisKey: String? = nil,
        isLiveTextHighlighted: Bool = false,
        onSingleTap: (() -> Void)? = nil,
        onZoomChanged: ((Bool) -> Void)? = nil,
        onLiveTextChanged: ((LiveTextStatus) -> Void)? = nil
    ) {
        self.image = image
        self.maximumZoomFactor = maximumZoomFactor
        self.analysisKey = analysisKey
        self.isLiveTextHighlighted = isLiveTextHighlighted
        self.onSingleTap = onSingleTap
        self.onZoomChanged = onZoomChanged
        self.onLiveTextChanged = onLiveTextChanged
    }

    public func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.maximumZoomFactor = maximumZoomFactor
        update(view)
        return view
    }

    public func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        update(view)
    }

    private func update(_ view: ZoomableImageScrollView) {
        view.onSingleTap = onSingleTap
        view.onZoomChanged = onZoomChanged
        view.onLiveTextChanged = onLiveTextChanged
        view.display(image)
        view.analyze(key: analysisKey)
        view.setLiveTextHighlighted(isLiveTextHighlighted)
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
    public var onZoomChanged: ((Bool) -> Void)?

    /// Whether the reader has zoomed in past the size that fits the screen.
    public var isZoomedIn: Bool { zoomScale > minimumZoomScale * 1.01 }
    /// What was last reported, so the gallery hears about changes only.
    private var lastReportedZoom = false

    public var onLiveTextChanged: ((LiveTextStatus) -> Void)?
    /// What was last reported, so the gallery hears about changes only.
    private var lastReportedLiveText = LiveTextStatus()
    #if canImport(VisionKit)
    /// Lifts text, codes and things to look up out of the picture. Nil where
    /// the device cannot analyse images.
    private var analysisInteraction: ImageAnalysisInteraction?
    private var analysisTask: Task<Void, Never>?
    #endif
    /// The picture the current analysis is for.
    private var analysisKey: String?

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
        // Off until the reader zooms in. An image that already fits has nothing
        // to scroll, and a scroll view that bounces anyway swallows the
        // downward drag the viewer above closes on.
        bounces = false

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

        #if canImport(VisionKit)
        if ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            interaction.delegate = self
            interaction.preferredInteractionTypes = .automatic
            // The gallery draws its own button, in its own bar. VisionKit's
            // sits on the picture, over the gallery's Save and Share.
            interaction.isSupplementaryInterfaceHidden = true
            imageView.addInteraction(interaction)
            analysisInteraction = interaction
        }
        #endif
    }

    /// Shows an image, resetting the zoom when it is a different one.
    public func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        forgetAnalysis()
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
        reportZoom()
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
        // A tap while the text is lifted out is a tap on the text, and hiding
        // the controls would hide the button that puts it back.
        guard !lastReportedLiveText.isHighlighted else { return }
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
        reportZoom()
        #if canImport(VisionKit)
        analysisInteraction?.setContentsRectNeedsUpdate()
        #endif
    }

    /// Tells the gallery whether the image is magnified, and lets the scroll
    /// view bounce only while it is.
    private func reportZoom() {
        let zoomed = isZoomedIn
        bounces = zoomed
        guard zoomed != lastReportedZoom else { return }
        lastReportedZoom = zoomed
        onZoomChanged?(zoomed)
    }

    // MARK: Live Text

    /// Looks for text in the picture, once it is the one on screen.
    ///
    /// Nil leaves whatever was found alone, so a page that stops being current
    /// keeps it for when the reader pages back.
    public func analyze(key: String?) {
        #if canImport(VisionKit)
        guard let key, key != analysisKey, let interaction = analysisInteraction,
              let image = imageView.image
        else { return }
        analysisKey = key
        analysisTask?.cancel()
        if let analysis = LiveTextCache.shared.analysis(for: key) {
            interaction.analysis = analysis
            reportLiveText()
            return
        }
        analysisTask = Task { [weak self] in
            let configuration = ImageAnalyzer.Configuration([.text, .visualLookUp, .machineReadableCode])
            guard let analysis = try? await LiveTextCache.shared.analyzer.analyze(image, configuration: configuration),
                  !Task.isCancelled, let self, self.imageView.image === image
            else { return }
            LiveTextCache.shared.remember(analysis, for: key)
            interaction.analysis = analysis
            self.reportLiveText()
        }
        #endif
    }

    /// Lifts the text out of the picture, or puts it back.
    public func setLiveTextHighlighted(_ highlighted: Bool) {
        #if canImport(VisionKit)
        guard let interaction = analysisInteraction, interaction.analysis != nil,
              interaction.selectableItemsHighlighted != highlighted
        else { return }
        interaction.selectableItemsHighlighted = highlighted
        reportLiveText()
        #endif
    }

    /// Drops what was found in the last picture, which says nothing about this one.
    private func forgetAnalysis() {
        analysisKey = nil
        #if canImport(VisionKit)
        analysisTask?.cancel()
        analysisInteraction?.analysis = nil
        analysisInteraction?.setContentsRectNeedsUpdate()
        #endif
        reportLiveText()
    }

    private func reportLiveText() {
        var status = LiveTextStatus()
        #if canImport(VisionKit)
        if let interaction = analysisInteraction, let analysis = interaction.analysis {
            status.isAvailable = analysis.hasResults(for: [.text, .visualLookUp, .machineReadableCode])
            status.isHighlighted = interaction.selectableItemsHighlighted
        }
        #endif
        guard status != lastReportedLiveText else { return }
        lastReportedLiveText = status
        onLiveTextChanged?(status)
    }
}

#if canImport(VisionKit)
extension ZoomableImageScrollView: ImageAnalysisInteractionDelegate {
    /// Only once the reader has asked for the text. Otherwise a long press on
    /// words in a screenshot selected them, where it opens the file's menu
    /// everywhere else in the gallery.
    public func interaction(
        _ interaction: ImageAnalysisInteraction,
        shouldBeginAt point: CGPoint,
        for interactionType: ImageAnalysisInteraction.InteractionTypes
    ) -> Bool {
        interaction.selectableItemsHighlighted || interaction.hasActiveTextSelection
    }

    public func interaction(
        _ interaction: ImageAnalysisInteraction,
        highlightSelectedItemsDidChange highlightSelectedItems: Bool
    ) {
        reportLiveText()
    }
}

/// The analyzer, and what it found in the last few pictures.
///
/// One analyzer for the app: it is costly to make and serves any number of
/// pictures. The analyses are kept so paging back to a picture does not
/// analyse it again; a handful is plenty, since only the page on screen is
/// ever analysed.
@MainActor
private final class LiveTextCache {
    static let shared = LiveTextCache()

    let analyzer = ImageAnalyzer()
    private var analyses: [String: ImageAnalysis] = [:]
    private var order: [String] = []
    private let limit = 8

    func analysis(for key: String) -> ImageAnalysis? {
        analyses[key]
    }

    func remember(_ analysis: ImageAnalysis, for key: String) {
        if analyses.updateValue(analysis, forKey: key) == nil {
            order.append(key)
        }
        while order.count > limit {
            analyses[order.removeFirst()] = nil
        }
    }
}
#endif
#endif
