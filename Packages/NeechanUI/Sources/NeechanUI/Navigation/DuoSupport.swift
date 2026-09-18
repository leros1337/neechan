import SwiftUI

// iPhone Duo, and the one place in the app its APIs are named.
//
// Three guards, not one, and each answers a different question.
//
// `#available` is a runtime question and does not help the compiler at all:
// `ArrangementView`, `ReservedRegion` and `toolbarVerticalEdge` are simply
// absent from the iOS 26 SDK, so naming them there fails the build rather than
// falling back. `compiler(>=6.4)` asks which SDK this is being compiled
// against -- Xcode 27 is the first to ship Swift 6.4, and the release workflow
// still pins Xcode 26.6. `os(iOS)` is the third: this package also builds for
// macOS so its logic can be tested without a simulator, and the macOS SDK is a
// version behind the iOS one, so the symbols are missing there too.
//
// Everything below falls back to what the app did before, so call sites read
// as ordinary SwiftUI and carry no guards of their own. When the deployment
// target eventually reaches iOS 27.1, the fallbacks are what gets deleted.

// MARK: - Vertical bars

extension EnvironmentValues {
    /// The edge the system stacked the bars along, or `nil` if they run
    /// horizontally as they do on every other iPhone.
    ///
    /// `nil` also on an SDK that has never heard of the question, which is why
    /// callers ask it this way round: "not vertical" is the answer that has
    /// always been true, and the one that stays true everywhere else.
    var duoVerticalBarEdge: HorizontalEdge? {
        #if compiler(>=6.4) && os(iOS)
        if #available(iOS 27.1, *) {
            return toolbarVerticalEdge
        }
        #endif
        return nil
    }
}

// MARK: - Reserved regions

/// The parts of a view that content should keep out of.
///
/// Two kinds, because they behave differently. A *division* is the fold: it
/// cuts the display into separate usable areas while the device is partly
/// open, and content either side of it is fine -- content across it is not.
/// An *occlusion* is hardware in the way, meaning a front camera; the outer
/// one is always there, the inner one only while the camera is live.
struct DuoRegions: Equatable {
    var divisions: [CGRect] = []
    var occlusions: [CGRect] = []

    var isEmpty: Bool { divisions.isEmpty && occlusions.isEmpty }

    /// Whether `rect` runs into anything it should not.
    func obstructs(_ rect: CGRect) -> Bool {
        (divisions + occlusions).contains { $0.intersects(rect) }
    }

    /// The largest piece of `bounds` that no division crosses.
    ///
    /// What a single view gets to use when it cannot be split in two: a
    /// picture, a video, a row of captcha keys. With the device open or shut
    /// there are no divisions and this is `bounds` itself, so callers can use
    /// it unconditionally.
    func largestSlice(of bounds: CGRect) -> CGRect {
        guard !divisions.isEmpty else { return bounds }

        // A fold reaches all the way across whichever way it runs, so each
        // division is a band, and which axis it cuts is decided by which way
        // it spans. Banked separately: a band across the width leaves slices
        // above and below it, one down the height leaves slices either side.
        var horizontalBands: [(CGFloat, CGFloat)] = []
        var verticalBands: [(CGFloat, CGFloat)] = []
        for division in divisions {
            let band = division.intersection(bounds)
            guard !band.isNull, !band.isEmpty else { continue }
            // A point of tolerance: these frames arrive in floating point and
            // an exact edge match is not something to rely on.
            if band.width >= bounds.width - 1 {
                horizontalBands.append((band.minY, band.maxY))
            } else if band.height >= bounds.height - 1 {
                verticalBands.append((band.minX, band.maxX))
            }
        }

        let rows = Self.gaps(from: bounds.minY, to: bounds.maxY, cutBy: horizontalBands)
        let columns = Self.gaps(from: bounds.minX, to: bounds.maxX, cutBy: verticalBands)

        // Every surviving rectangle, largest first. Both axes are considered
        // rather than just the folding one, so a pose that somehow divides
        // twice still yields a real answer instead of a negative size.
        var best = CGRect.zero
        for (top, bottom) in rows {
            for (left, right) in columns {
                let candidate = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                if candidate.width * candidate.height > best.width * best.height {
                    best = candidate
                }
            }
        }
        return best.isEmpty ? bounds : best
    }

    /// The stretches of `lower...upper` that none of `cuts` covers.
    private static func gaps(
        from lower: CGFloat,
        to upper: CGFloat,
        cutBy cuts: [(CGFloat, CGFloat)]
    ) -> [(CGFloat, CGFloat)] {
        guard !cuts.isEmpty else { return [(lower, upper)] }
        var result: [(CGFloat, CGFloat)] = []
        var cursor = lower
        for (start, end) in cuts.sorted(by: { $0.0 < $1.0 }) {
            if start > cursor { result.append((cursor, start)) }
            cursor = max(cursor, end)
        }
        if cursor < upper { result.append((cursor, upper)) }
        return result
    }
}

extension GeometryProxy {
    /// What this view has to work around, in its own coordinate space.
    ///
    /// Empty everywhere but a folding iPhone, so a caller can read it and then
    /// write the same layout code for every device.
    var duoRegions: DuoRegions {
        #if compiler(>=6.4) && os(iOS)
        if #available(iOS 27.1, *) {
            return DuoRegions(
                divisions: reservedRegions(kind: .division).map(\.frame),
                occlusions: reservedRegions(kind: .occlusion).map(\.frame)
            )
        }
        #endif
        return DuoRegions()
    }
}

// MARK: - Arrangements

/// Two views the system may lay out together, apart, or one over the other,
/// depending on how the device is being held.
///
/// Wraps `ArrangementView`, and falls back to the stack that arrangement
/// degrades to, so the shape of the call site is the same either way.
struct DuoArrangement<Primary: View, Secondary: View>: View {
    enum Style {
        /// Primary over secondary, until the fold gives them a side each.
        case overlay
        /// Primary beside or above secondary, splitting the space between them.
        case split
    }

    private let style: Style
    private let axes: Axis.Set?
    private let primary: Primary
    private let secondary: Secondary

    /// - Parameter axes: the directions the arrangement is allowed to use, or
    ///   `nil` to let it pick from the space it is given.
    init(
        _ style: Style,
        axes: Axis.Set? = nil,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.style = style
        self.axes = axes
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        #if compiler(>=6.4) && os(iOS)
        if #available(iOS 27.1, *) {
            arranged
        } else {
            stacked
        }
        #else
        stacked
        #endif
    }

    #if compiler(>=6.4) && os(iOS)
    @available(iOS 27.1, *)
    @ViewBuilder
    private var arranged: some View {
        let view = ArrangementView {
            primary
        } secondary: {
            secondary
        }
        switch style {
        case .overlay:
            if let axes {
                view.arrangementViewStyle(.overlay.axes(axes))
            } else {
                view.arrangementViewStyle(.overlay)
            }
        case .split:
            if let axes {
                view.arrangementViewStyle(.split.axes(axes))
            } else {
                view.arrangementViewStyle(.split)
            }
        }
    }
    #endif

    /// What each arrangement becomes with nothing to adapt to, which is also
    /// exactly what these call sites were written as before.
    @ViewBuilder
    private var stacked: some View {
        switch style {
        case .overlay:
            ZStack {
                secondary
                primary
            }
        case .split:
            if axes == .vertical {
                VStack(spacing: 0) {
                    primary
                    secondary
                }
            } else {
                HStack(spacing: 0) {
                    primary
                    secondary
                }
            }
        }
    }
}

// MARK: - Sheets

/// Which side of the inner display a sheet should come up on.
///
/// The placement also decides the sheet's own bars: trailing gets them down
/// the side, centred and leading keep them across the top.
enum DuoPresentationPlacement {
    case automatic
    case leading
    case center
    case trailing
}

extension View {
    @ViewBuilder
    func duoPresentationPlacement(_ placement: DuoPresentationPlacement) -> some View {
        #if compiler(>=6.4) && os(iOS)
        if #available(iOS 27.0, *) {
            presentationPlacement(placement.resolved)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if compiler(>=6.4) && os(iOS)
@available(iOS 27.0, *)
extension DuoPresentationPlacement {
    fileprivate var resolved: PresentationPlacement {
        switch self {
        case .automatic: .automatic
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
#endif

// MARK: - Working around what is in the way

extension DuoRegions {
    /// Padding that keeps content out from under the hardware.
    ///
    /// Each occlusion is charged to whichever edge of `bounds` it sits nearest,
    /// so a camera in a corner costs a strip down one side rather than a band
    /// across the whole view.
    func occlusionInsets(in bounds: CGRect) -> EdgeInsets {
        var insets = EdgeInsets()
        for occlusion in occlusions {
            let covered = occlusion.intersection(bounds)
            guard !covered.isNull, !covered.isEmpty else { continue }

            let fromLeading = covered.maxX - bounds.minX
            let fromTrailing = bounds.maxX - covered.minX
            let fromTop = covered.maxY - bounds.minY
            let fromBottom = bounds.maxY - covered.minY

            switch min(fromLeading, fromTrailing, fromTop, fromBottom) {
            case fromLeading: insets.leading = max(insets.leading, fromLeading)
            case fromTrailing: insets.trailing = max(insets.trailing, fromTrailing)
            case fromTop: insets.top = max(insets.top, fromTop)
            default: insets.bottom = max(insets.bottom, fromBottom)
            }
        }
        return insets
    }

    /// How many columns of at least `minimum` fit across `width`, rounded down
    /// to an even number while the display is folded.
    ///
    /// An odd column count puts a column of cells over the fold. An even one
    /// divides either side of it, which is what the guidance asks for and what
    /// makes a grid look deliberate rather than caught mid-reflow.
    func evenedColumnCount(fitting width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        let fits = max(1, Int((width + spacing) / (minimum + spacing)))
        // One column cannot be evened without becoming none.
        guard !divisions.isEmpty, fits > 1 else { return fits }
        return fits - (fits % 2)
    }
}

extension View {
    /// Keeps this view clear of anything the hardware covers.
    ///
    /// Nothing anywhere but a folding iPhone, where it moves content out from
    /// under a front camera -- the outer one always, the inner one while it is
    /// live.
    func duoAvoidingOcclusions() -> some View {
        modifier(DuoOcclusionPadding())
    }
}

private struct DuoOcclusionPadding: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .padding(insets)
            // Measured after the padding, not before: what is read back is the
            // frame this view was offered either way, so the measurement that
            // sets the padding cannot be changed by it. Reading it the other
            // way round shrinks the view, which moves the edges, which sets a
            // different padding, and so on.
            .onGeometryChange(for: EdgeInsets.self) { proxy in
                proxy.duoRegions.occlusionInsets(
                    in: CGRect(origin: .zero, size: proxy.size)
                )
            } action: { insets = $0 }
    }
}

// MARK: - Grids

/// A grid whose columns divide cleanly either side of a fold.
///
/// `.adaptive` everywhere else, which is what these grids have always been and
/// what keeps a phone and an iPad exactly as they were. Only a part-folded
/// iPhone Duo takes the other path, where the column count is fixed and even
/// so that no column of cells straddles the crease.
struct DuoAdaptiveGrid<Content: View>: View {
    private let minimum: CGFloat
    private let spacing: CGFloat
    private let content: Content

    /// The even count to use while folded, or `nil` for the adaptive columns
    /// that every other device gets.
    @State private var foldedColumns: Int?

    init(minimum: CGFloat, spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.minimum = minimum
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        // Lifted out of the closure below rather than read through `self`.
        // That closure is `@Sendable`, and reaching into a generic view from
        // inside one captures the view's type as well as the two numbers
        // wanted, which under complete concurrency checking is a warning.
        let minimum = minimum
        let spacing = spacing

        LazyVGrid(columns: columns, spacing: spacing) {
            content
        }
        .onGeometryChange(for: Int?.self) { proxy in
            let regions = proxy.duoRegions
            guard !regions.divisions.isEmpty else { return nil }
            return regions.evenedColumnCount(
                fitting: proxy.size.width, minimum: minimum, spacing: spacing
            )
        } action: { foldedColumns = $0 }
    }

    private var columns: [GridItem] {
        guard let foldedColumns else {
            return [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
        }
        // Flexible without a minimum of its own: the count already came from
        // what fits at `minimum`, and restating it here would let the row
        // overflow rather than divide.
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing), count: foldedColumns
        )
    }
}
