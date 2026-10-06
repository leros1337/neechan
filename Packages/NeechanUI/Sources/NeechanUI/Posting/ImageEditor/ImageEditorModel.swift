import CoreGraphics
import Foundation
import NeechanCore
import Observation

/// Drives the image editor: what has been done to the picture, what the
/// reader's finger is doing now, and the preview.
///
/// Everything the canvas sends is in screen points; the model turns those
/// into the photo's own pixels, so a stroke lands on the same spot of the
/// photo whatever the screen, the zoom or the turn.
@MainActor
@Observable
final class ImageEditorModel {
    enum Phase: Equatable {
        case loading
        case ready
        case exporting
        /// Not a still picture, or it could not be read or written.
        case failed
    }

    enum Mode: Hashable, CaseIterable {
        case draw
        case crop
        case resize
    }

    enum Tool: Hashable, CaseIterable {
        case pen
        case arrow
        case pixelate
        case text
    }

    enum Outcome: Equatable {
        /// Nothing to write: the reader changed nothing.
        case unchanged
        case edited(ImageEditOutput)
        case failed
    }

    /// A label being typed, kept apart from the edit until the reader is done.
    struct LabelEditing: Equatable {
        var id: UUID
        /// Not on the picture yet; dropped if left empty.
        var isNew: Bool
        var label: ImageEditLabel
    }

    /// Telegram's eight, and black for drawing on a white page.
    static let presetColors: [ThemeColor] = [
        "ff453a", "ff8a00", "ffd60a", "34c759", "63e6e2", "0a84ff", "bf5af2", "ffffff", "000000",
    ].compactMap { ThemeColor(cssLike: $0) }

    /// The preview never needs more than a screen's worth of the photo.
    static let previewMaxPixelSize = 2048

    /// How far from a crop handle a touch still takes hold of it, in points.
    static let handleReach: CGFloat = 24

    // MARK: State

    private(set) var phase: Phase = .loading
    private(set) var source: ImageEditSource?
    private var data: Data?
    private var initialEdit: ImageEdit?

    /// The edit as it is on screen, including a crop or slider drag in progress.
    private(set) var edit = ImageEdit(uprightSize: PixelSize(width: 1, height: 1)) {
        didSet { schedulePreview() }
    }
    /// Steps the reader can undo; `edit` is recorded into it when a change is done.
    private var history = EditHistory(ImageEdit(uprightSize: PixelSize(width: 1, height: 1)))

    var mode: Mode = .draw {
        didSet {
            guard mode != oldValue else { return }
            finishEditingLabel()
            cancelGesture()
            schedulePreview()
        }
    }

    var tool: Tool = .pen {
        didSet {
            if oldValue == .text, tool != .text { finishEditingLabel() }
        }
    }

    var color: ThemeColor = presetColors[0] {
        didSet { labelEditing?.label.color = color }
    }

    /// Line and brush widths, and the text size, each in screen points.
    private var sizes: [Tool: CGFloat] = [.pen: 6, .arrow: 6, .pixelate: 36, .text: 28]

    /// The current tool's size, in screen points.
    var size: CGFloat {
        get { sizes[tool] ?? 6 }
        set {
            sizes[tool] = newValue
            if tool == .text, labelEditing != nil, viewScale > 0 {
                labelEditing?.label.fontSize = newValue / viewScale
            }
        }
    }

    static func sizeRange(for tool: Tool) -> ClosedRange<CGFloat> {
        switch tool {
        case .pen, .arrow: 2...30
        case .pixelate: 12...96
        case .text: 12...96
        }
    }

    private(set) var cropAspect: ImageCropAspect = .free

    /// Where the canvas may draw, in its own points.
    var canvasBounds: CGRect = .zero

    /// The stroke or arrow under the finger, not yet part of the edit.
    private(set) var activeMark: ImageEditMark?
    private(set) var labelEditing: LabelEditing? {
        didSet {
            if labelEditing?.id != oldValue?.id || labelEditing?.isNew != oldValue?.isNew {
                schedulePreview()
            }
        }
    }

    /// The last preview drawn, and what it was drawn from.
    private(set) var preview: CGImage?
    private(set) var renderedKey: PreviewKey?
    private var previewBase: CGImage?
    private var renderTask: Task<Void, Never>?

    private var gesture: Gesture?
    /// Where the current drag began, to tell a new drag from the same one.
    private var gestureStart: CGPoint?

    private enum Gesture {
        case stroke
        case crop(handle: ImageCropHandle, startRect: CGRect)
        case label(id: UUID, startCenter: CGPoint, moved: Bool)
        case tap
        /// A touch that only put down the label being typed.
        case ignored
    }

    // MARK: Loading

    /// Opens a picked file; anything but a still picture fails.
    func load(data: Data, scalePercent: Int?) async {
        guard let source = ImageEditSource(data: data), source.isEditable else {
            phase = .failed
            return
        }
        self.data = data
        self.source = source
        let initial = ImageEdit(uprightSize: source.uprightSize, scalePercent: scalePercent ?? 100)
        initialEdit = initial
        history = EditHistory(initial)
        edit = initial

        let maxPixelSize = Self.previewMaxPixelSize
        let base = await Task.detached(priority: .userInitiated) {
            ImageEditSource.decodeUpright(data, maxPixelSize: maxPixelSize)
        }.value
        guard let base else {
            phase = .failed
            return
        }
        previewBase = base
        phase = .ready
        schedulePreview()
    }

    // MARK: Sizes

    var originalPixelSize: PixelSize {
        edit.uprightSize
    }

    var outputPixelSize: PixelSize {
        ImageEditGeometry(edit).outputPixelSize
    }

    var scalePercent: Int {
        get { edit.scalePercent }
        set {
            edit.scalePercent = min(max(newValue, ImageEdit.scaleRange.lowerBound), ImageEdit.scaleRange.upperBound)
        }
    }

    /// A slider drag is one step, recorded when the finger lifts.
    func scaleEditingChanged(_ editing: Bool) {
        if !editing { commit() }
    }

    /// For a stepper, where each tap is a step of its own.
    func stepScale(to percent: Int) {
        scalePercent = percent
        commit()
    }

    // MARK: Geometry

    /// What the canvas shows, in the turned picture: all of it while
    /// cropping, the crop otherwise.
    var displayRegion: CGRect {
        let geometry = ImageEditGeometry(edit)
        return mode == .crop ? CGRect(origin: .zero, size: geometry.orientedSize) : geometry.orientedCrop
    }

    /// Where the picture sits on the canvas.
    var viewport: CGRect {
        ImageEditGeometry.fit(displayRegion.size, in: canvasBounds)
    }

    /// Screen points per pixel of the photo.
    var viewScale: CGFloat {
        let region = displayRegion
        return region.width > 0 ? viewport.width / region.width : 0
    }

    /// The photo's pixels to the canvas's points.
    var uprightToView: CGAffineTransform {
        let region = displayRegion
        let scale = viewScale
        let origin = viewport.origin
        return ImageEditGeometry(edit).orientation
            .concatenating(CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    func orientedPoint(fromView point: CGPoint) -> CGPoint {
        let region = displayRegion
        let scale = viewScale
        guard scale > 0 else { return .zero }
        return CGPoint(
            x: (point.x - viewport.minX) / scale + region.minX,
            y: (point.y - viewport.minY) / scale + region.minY
        )
    }

    func viewRect(fromOriented rect: CGRect) -> CGRect {
        let region = displayRegion
        let scale = viewScale
        return CGRect(
            x: (rect.minX - region.minX) * scale + viewport.minX,
            y: (rect.minY - region.minY) * scale + viewport.minY,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func uprightPoint(fromView point: CGPoint) -> CGPoint {
        ImageEditGeometry(edit).toUpright(orientedPoint(fromView: point))
    }

    /// The crop frame on screen, while cropping.
    var cropRectInView: CGRect? {
        guard mode == .crop else { return nil }
        return viewRect(fromOriented: ImageEditGeometry(edit).orientedCrop)
    }

    // MARK: Gestures

    /// A finger down or moving on the canvas. The first call of a drag
    /// decides what it does.
    func dragChanged(start: CGPoint, location: CGPoint) {
        guard phase == .ready, viewScale > 0 else { return }
        // A drag that never ended was taken away by the system; whatever it
        // drew is kept before the new one begins.
        if let gestureStart, gestureStart != start {
            cancelGesture()
        }
        if gesture == nil, gestureStart == nil {
            gestureStart = start
            begin(at: start)
        }
        guard let gesture else { return }

        switch gesture {
        case .stroke:
            extendStroke(to: location)
        case .crop(let handle, let startRect):
            let scale = viewScale
            let translation = CGSize(
                width: (location.x - start.x) / scale,
                height: (location.y - start.y) / scale
            )
            let geometry = ImageEditGeometry(edit)
            let rect = ImageCropping.drag(
                handle,
                from: startRect,
                by: translation,
                bounds: geometry.orientedSize,
                aspect: cropAspect.ratio(for: geometry.orientedSize),
                minSide: ImageCropping.minimumSide(for: geometry.orientedSize)
            )
            edit.crop = ImageCropping.uprightCrop(fromOriented: rect, geometry: geometry)
        case .label(let id, let startCenter, let moved):
            let distance = hypot(location.x - start.x, location.y - start.y)
            guard moved || distance > Self.tapSlop else { return }
            self.gesture = .label(id: id, startCenter: startCenter, moved: true)
            let scale = viewScale
            let center = CGPoint(
                x: startCenter.x + (location.x - start.x) / scale,
                y: startCenter.y + (location.y - start.y) / scale
            )
            moveLabel(id, toOriented: center)
        case .tap, .ignored:
            break
        }
    }

    /// The finger lifted: whatever the drag made becomes one step.
    func dragEnded(start: CGPoint, location: CGPoint) {
        if gestureStart == nil {
            dragChanged(start: start, location: location)
        }
        gestureStart = nil
        guard let gesture else { return }
        self.gesture = nil

        switch gesture {
        case .stroke:
            extendStroke(to: location)
            commitStroke()
        case .crop:
            commit()
        case .label(let id, _, let moved):
            if moved {
                commit()
            } else {
                beginEditingLabel(id)
            }
        case .tap:
            if hypot(location.x - start.x, location.y - start.y) <= Self.tapSlop {
                placeLabel(atView: start)
            }
        case .ignored:
            break
        }
    }

    /// A drag the system took away: keep what was drawn, as if it had ended.
    func cancelGesture() {
        gestureStart = nil
        guard gesture != nil else { return }
        gesture = nil
        if activeMark != nil {
            commitStroke()
        } else {
            commit()
        }
    }

    /// Movement under this many points is a tap.
    private static let tapSlop: CGFloat = 6

    private func begin(at point: CGPoint) {
        switch mode {
        case .draw:
            switch tool {
            case .pen, .arrow, .pixelate:
                finishEditingLabel()
                beginStroke(at: point)
                gesture = .stroke
            case .text:
                if labelEditing != nil {
                    // Tapping away from the label being typed puts it down,
                    // as on the keyboard's own Done; it does not start another.
                    finishEditingLabel()
                    gesture = .ignored
                } else if let id = ImageEditLabels.hit(orientedPoint(fromView: point), in: edit, padding: 8 / viewScale),
                   let label = edit.marks.first(where: { $0.id == id })?.label
                {
                    finishEditingLabel()
                    gesture = .label(
                        id: id,
                        startCenter: ImageEditGeometry(edit).toOriented(label.center),
                        moved: false
                    )
                } else {
                    gesture = .tap
                }
            }
        case .crop:
            guard let frame = cropRectInView,
                  let handle = ImageCropHandle.hit(point, in: frame, tolerance: Self.handleReach)
            else {
                return
            }
            gesture = .crop(handle: handle, startRect: ImageEditGeometry(edit).orientedCrop)
        case .resize:
            break
        }
    }

    // MARK: Strokes

    private func beginStroke(at point: CGPoint) {
        let position = uprightPoint(fromView: point)
        let width = size / viewScale
        switch tool {
        case .pen:
            activeMark = ImageEditMark(kind: .pen(points: [position], width: width, color: color))
        case .pixelate:
            activeMark = ImageEditMark(kind: .pixelate(points: [position], width: width))
        case .arrow:
            activeMark = ImageEditMark(kind: .arrow(from: position, to: position, width: width, color: color))
        case .text:
            break
        }
    }

    private func extendStroke(to point: CGPoint) {
        guard var mark = activeMark else { return }
        let position = uprightPoint(fromView: point)
        // A point a screen point from the last adds nothing a curve needs.
        let spacing = 1 / viewScale
        switch mark.kind {
        case .pen(let points, let width, let color):
            mark.kind = .pen(
                points: ImageEditStrokes.appending(position, to: points, minDistance: spacing),
                width: width, color: color
            )
        case .pixelate(let points, let width):
            mark.kind = .pixelate(
                points: ImageEditStrokes.appending(position, to: points, minDistance: spacing),
                width: width
            )
        case .arrow(let from, _, let width, let color):
            mark.kind = .arrow(from: from, to: position, width: width, color: color)
        case .label:
            break
        }
        activeMark = mark
    }

    private func commitStroke() {
        guard let mark = activeMark else { return }
        activeMark = nil
        // An arrow needs a direction; a tap with the arrow tool draws nothing.
        if case .arrow(let from, let to, _, _) = mark.kind,
           hypot(to.x - from.x, to.y - from.y) * viewScale < 8
        {
            return
        }
        edit.marks.append(mark)
        commit()
    }

    // MARK: Labels

    /// The text of the label being typed.
    var labelText: String {
        get { labelEditing?.label.text ?? "" }
        set { labelEditing?.label.text = newValue }
    }

    private func placeLabel(atView point: CGPoint) {
        finishEditingLabel()
        labelEditing = LabelEditing(
            id: UUID(),
            isNew: true,
            label: ImageEditLabel(
                text: "",
                center: uprightPoint(fromView: point),
                fontSize: (sizes[.text] ?? 28) / viewScale,
                color: color
            )
        )
    }

    private func beginEditingLabel(_ id: UUID) {
        guard let label = edit.marks.first(where: { $0.id == id })?.label else { return }
        finishEditingLabel()
        // The pickers show the label's own colour and size while it is open.
        color = label.color
        sizes[.text] = label.fontSize * viewScale
        labelEditing = LabelEditing(id: id, isNew: false, label: label)
    }

    private func moveLabel(_ id: UUID, toOriented center: CGPoint) {
        guard let index = edit.marks.firstIndex(where: { $0.id == id }),
              var label = edit.marks[index].label
        else {
            return
        }
        label.center = ImageEditGeometry(edit).toUpright(center)
        edit.marks[index].kind = .label(label)
    }

    /// Puts the typed label on the picture, or takes it off if left empty.
    func finishEditingLabel() {
        guard var editing = labelEditing else { return }
        labelEditing = nil
        editing.label.text = editing.label.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var marks = edit.marks
        if let index = marks.firstIndex(where: { $0.id == editing.id }) {
            if editing.label.text.isEmpty {
                marks.remove(at: index)
            } else {
                marks[index].kind = .label(editing.label)
            }
        } else if !editing.label.text.isEmpty {
            marks.append(ImageEditMark(id: editing.id, kind: .label(editing.label)))
        }
        edit.marks = marks
        commit()
    }

    /// The label being typed, as it sits on the canvas.
    var labelEditingFrameInView: (center: CGPoint, fontSize: CGFloat)? {
        guard let editing = labelEditing else { return nil }
        return (editing.label.center.applying(uprightToView), editing.label.fontSize * viewScale)
    }

    // MARK: Crop

    func turn(clockwise: Bool) {
        finishEditingLabel()
        edit = edit.turned(clockwise: clockwise)
        cropAspect = cropAspect.turned
        commit()
    }

    func mirror() {
        finishEditingLabel()
        edit = edit.mirroredAsSeen()
        commit()
    }

    func setAspect(_ aspect: ImageCropAspect) {
        cropAspect = aspect
        let geometry = ImageEditGeometry(edit)
        guard let ratio = aspect.ratio(for: geometry.orientedSize) else { return }
        let current = geometry.orientedCrop
        let fitted = ImageCropping.fitted(
            aspect: ratio,
            in: geometry.orientedSize,
            around: CGPoint(x: current.midX, y: current.midY)
        )
        edit.crop = ImageCropping.uprightCrop(fromOriented: fitted, geometry: geometry)
        commit()
    }

    /// The whole photo, the right way round; drawing and scale are kept.
    func resetCrop() {
        edit.crop = edit.fullCrop
        edit.quarterTurns = 0
        edit.isMirrored = false
        cropAspect = .free
        commit()
    }

    // MARK: History

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        finishEditingLabel()
        history.undo()
        edit = history.current
    }

    func redo() {
        finishEditingLabel()
        history.redo()
        edit = history.current
    }

    private func commit() {
        history.record(edit)
    }

    /// Whether leaving would lose something.
    var hasChanges: Bool {
        guard let initialEdit else { return false }
        let typing = !(labelEditing?.label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return edit != initialEdit || typing
    }

    // MARK: Finishing

    /// Writes the edited picture, unless nothing was changed.
    func finish() async -> Outcome {
        finishEditingLabel()
        cancelGesture()
        guard let data, let initialEdit, edit != initialEdit else { return .unchanged }

        phase = .exporting
        let edit = edit
        let output = await Task.detached(priority: .userInitiated) {
            try? ImageEditRenderer.export(data, edit: edit)
        }.value
        guard let output else {
            phase = .failed
            return .failed
        }
        phase = .ready
        return .edited(output)
    }

    // MARK: Preview

    /// What a preview was drawn from: the edit as the canvas shows it.
    ///
    /// The scale never changes what is on screen, and while cropping neither
    /// does the crop, so neither asks for a new drawing.
    struct PreviewKey: Equatable {
        var edit: ImageEdit
        var cropped: Bool
        var hidden: UUID?
    }

    private var previewKey: PreviewKey {
        var keyEdit = edit
        keyEdit.scalePercent = 100
        let cropped = mode != .crop
        if !cropped {
            keyEdit.crop = keyEdit.fullCrop
        }
        let hidden = labelEditing.flatMap { $0.isNew ? nil : $0.id }
        return PreviewKey(edit: keyEdit, cropped: cropped, hidden: hidden)
    }

    /// Whether the preview on screen was drawn from the edit as it is now.
    var isPreviewCurrent: Bool {
        preview != nil && renderedKey == previewKey
    }

    /// Where the last preview goes on the canvas.
    ///
    /// Placed by what it was drawn from rather than by the current edit, so
    /// for the moment between a turn and its new drawing the old picture keeps
    /// its own shape instead of being stretched into the new one.
    var previewFrame: CGRect? {
        guard let key = renderedKey else { return nil }
        let geometry = ImageEditGeometry(key.edit)
        let region = key.cropped ? geometry.orientedCrop.size : geometry.orientedSize
        return ImageEditGeometry.fit(region, in: canvasBounds)
    }

    /// Marks already in the edit but not yet in the preview, drawn over it
    /// until the next preview catches up, so a finished stroke never blinks.
    var overlayMarks: [ImageEditMark] {
        let rendered = Set(renderedKey?.edit.marks.map(\.id) ?? [])
        let pending = edit.marks.filter { !rendered.contains($0.id) && $0.label == nil }
        return pending + (activeMark.map { [$0] } ?? [])
    }

    private func schedulePreview() {
        guard let base = previewBase else { return }
        let key = previewKey
        guard key != renderedKey else { return }

        renderTask?.cancel()
        let pixelScale = CGFloat(base.width) / CGFloat(max(1, key.edit.uprightSize.width))
        let size = ImageEditRenderer.canvasSize(for: key.edit, pixelScale: pixelScale, cropped: key.cropped)
        renderTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ImageEditRenderer.render(
                    base: base, edit: key.edit, canvasSize: size, cropped: key.cropped, hiding: key.hidden
                )
            }.value
            guard !Task.isCancelled, let self, let image else { return }
            self.preview = image
            self.renderedKey = key
        }
    }
}

extension ImageCropAspect {
    /// The same lock after a quarter turn: a wide crop becomes a tall one.
    var turned: ImageCropAspect {
        switch self {
        case .fourThree: .threeFour
        case .threeFour: .fourThree
        case .sixteenNine: .nineSixteen
        case .nineSixteen: .sixteenNine
        case .free, .original, .square: self
        }
    }
}
