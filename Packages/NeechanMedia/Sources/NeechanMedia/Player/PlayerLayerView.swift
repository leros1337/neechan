import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Puts the player's layer on screen.
///
/// The layer belongs to the player rather than to the view, because one player
/// can outlive the clip it is showing: a feed that swaps the URL keeps the
/// same layer, and so keeps the picture rather than flashing to nothing
/// between clips.
struct PlayerLayerView {
    let displayLayer: AVSampleBufferDisplayLayer
    /// How far to turn the picture, from the file's own metadata.
    let rotationDegrees: Double
}

/// A view whose only job is to hold the layer and keep it the right size.
final class DisplayLayerHost: PlatformView {
    private var hosted: AVSampleBufferDisplayLayer?
    private var rotation: Double = 0

    func show(_ layer: AVSampleBufferDisplayLayer, rotatedBy degrees: Double) {
        #if !canImport(UIKit)
        wantsLayer = true
        #endif
        if hosted !== layer {
            hosted?.removeFromSuperlayer()
            hosted = layer
            backingLayer?.addSublayer(layer)
        }
        rotation = degrees
        layOutHostedLayer()
    }

    func layOutHostedLayer() {
        guard let hosted, let backingLayer else { return }
        // Without this the layer animates to every new size, which on rotation
        // or a size change reads as the picture sliding about.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let bounds = backingLayer.bounds
        let isQuarterTurn = abs(rotation.truncatingRemainder(dividingBy: 180)) == 90
        // A quarter turn swaps the sides, so the layer is laid out in the
        // shape it will occupy once turned and then turned into place.
        hosted.bounds = isQuarterTurn
            ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            : bounds
        hosted.position = CGPoint(x: bounds.midX, y: bounds.midY)
        hosted.setAffineTransform(
            rotation == 0 ? .identity : CGAffineTransform(rotationAngle: rotation * .pi / 180)
        )

        CATransaction.commit()

        // Only when something changed, so a page that lays out every frame
        // during a swipe does not drown the log. What this answers: whether a
        // picture that appears off to one side is drawn off to one side, or
        // is drawn correctly in a page that is itself off to one side.
        let placed = hosted.frame
        if placed != lastReportedFrame {
            lastReportedFrame = placed
            MediaLog.output.debug(
                """
                layer laid out: host \(String(describing: bounds), privacy: .public), \
                picture \(String(describing: placed), privacy: .public), \
                rotated \(self.rotation, format: .fixed(precision: 0), privacy: .public)°
                """
            )
        }
    }

    private var lastReportedFrame: CGRect = .null

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        layOutHostedLayer()
    }
    private var backingLayer: CALayer? { layer }
    #else
    override func layout() {
        super.layout()
        layOutHostedLayer()
    }
    private var backingLayer: CALayer? { layer }
    #endif
}

#if canImport(UIKit)
typealias PlatformView = UIView

extension PlayerLayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> DisplayLayerHost {
        let host = DisplayLayerHost()
        host.backgroundColor = .black
        host.show(displayLayer, rotatedBy: rotationDegrees)
        return host
    }

    func updateUIView(_ host: DisplayLayerHost, context: Context) {
        host.show(displayLayer, rotatedBy: rotationDegrees)
    }
}
#else
typealias PlatformView = NSView

extension PlayerLayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> DisplayLayerHost {
        let host = DisplayLayerHost()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.show(displayLayer, rotatedBy: rotationDegrees)
        return host
    }

    func updateNSView(_ host: DisplayLayerHost, context: Context) {
        host.show(displayLayer, rotatedBy: rotationDegrees)
    }
}
#endif
