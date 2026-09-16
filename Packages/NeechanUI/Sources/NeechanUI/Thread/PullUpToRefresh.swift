import SwiftUI

/// How far past the end of a thread the reader has dragged.
///
/// A value rather than loose state so the arming rule is one thing that can be
/// reasoned about and tested, instead of arithmetic spread through a view.
struct PullUpProgress: Equatable {
    /// How far the reader must drag past the end before releasing refreshes.
    var threshold: CGFloat = 72
    /// How far past the end the content currently is, never negative.
    private(set) var distance: CGFloat = 0
    /// The content height the last reading came from.
    private var contentHeight: CGFloat = 0

    /// 0 while at rest, 1 once far enough to refresh.
    var fraction: Double {
        guard threshold > 0 else { return 0 }
        return min(1, max(0, Double(distance / threshold)))
    }

    /// Whether the reader has dragged far enough that letting go will refresh.
    private(set) var isArmed = false

    /// Spelled out rather than left to the memberwise initialiser: a private
    /// stored property makes that one private too on Swift 6.2, so the tests
    /// could not build it. Swift 6.3 is happy either way, which is why this
    /// only showed up on CI.
    init(threshold: CGFloat = 72) {
        self.threshold = threshold
    }

    /// Whether the indicator is worth showing at all.
    ///
    /// A few points of rubber-banding happen on any flick to the end, and an
    /// indicator flashing up on every one of those would be noise.
    var isVisible: Bool { distance > 8 }

    /// Takes a new overscroll reading.
    ///
    /// - Returns: true at the moment the refresh should start.
    ///
    /// Firing is recognised by the content springing back rather than by the
    /// scroll view reporting that the finger lifted: the phase change does not
    /// arrive for every gesture, and a pull that armed and then sprang back is
    /// exactly what letting go looks like.
    mutating func update(overscroll: CGFloat) -> Bool {
        update(PullUpReading(
            overscroll: overscroll, contentHeight: contentHeight, isScrollable: true
        ))
    }

    /// Takes a reading of the whole scroll geometry.
    ///
    /// Two of these three values are here because the thread used to refresh
    /// itself the moment it opened: the scroll view is built before the posts
    /// arrive, so it briefly holds less than a screenful and reports an
    /// overscroll of about a screen height, which armed the pull with nobody
    /// touching the glass. When the posts landed the distance collapsed, and a
    /// collapse is exactly what letting go looks like.
    mutating func update(_ reading: PullUpReading) -> Bool {
        // Nothing to pull up from: the thread is shorter than the screen.
        guard reading.isScrollable else {
            contentHeight = reading.contentHeight
            reset()
            return false
        }
        // The end of the list moved under the reader. Whatever the numbers do
        // across that change is layout, not a gesture.
        guard reading.contentHeight == contentHeight else {
            contentHeight = reading.contentHeight
            reset()
            return false
        }

        distance = max(0, reading.overscroll)

        if distance >= threshold {
            isArmed = true
            return false
        }
        // Retreating from an armed pull: the reader let go.
        if isArmed, distance < threshold / 2 {
            isArmed = false
            return true
        }
        return false
    }

    mutating func reset() {
        distance = 0
        isArmed = false
    }
}

/// One look at the scroll view's geometry.
struct PullUpReading: Equatable {
    /// How far the content is past its own end; negative above it.
    var overscroll: CGFloat
    /// Total content height, watched because a change to it is a relayout.
    var contentHeight: CGFloat
    /// Whether there is more content than screen, so a pull is possible at all.
    var isScrollable: Bool
}

/// Pull up past the end of a thread to refresh it.
///
/// The site's own readers expect this from Dashchan: new posts arrive at the
/// bottom, which is where the reader already is, so reaching back to the top to
/// pull down is the wrong end of the screen.
private struct PullUpToRefreshModifier: ViewModifier {
    let action: () async -> Void

    @State private var progress = PullUpProgress()
    @State private var isRefreshing = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: PullUpReading.self) { geometry in
                // Distance the content has been pulled past its own end.
                //
                // The offsets here are the scroll view's own: the content is
                // laid out under the navigation bar, so resting at the end puts
                // `contentOffset` one top inset short of the content height.
                // Measured against the real geometry rather than derived, which
                // is why the top inset appears on this side of the subtraction.
                let end = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentInsets.top
                return PullUpReading(
                    overscroll: geometry.contentOffset.y - end,
                    contentHeight: geometry.contentSize.height,
                    isScrollable: geometry.contentSize.height > geometry.containerSize.height
                )
            } action: { _, reading in
                guard !isRefreshing else { return }
                if progress.update(reading) {
                    refresh()
                }
            }
            .overlay(alignment: .bottom) { indicator }
    }

    @ViewBuilder
    private var indicator: some View {
        if isRefreshing || progress.isVisible {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(progress.isArmed || isRefreshing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                // The icon turns as it is pulled, so the gesture reads as
                // winding something up rather than as a button appearing.
                .rotationEffect(.degrees(isRefreshing ? 0 : progress.fraction * 270))
                .scaleEffect(isRefreshing ? 1 : 0.6 + 0.4 * progress.fraction)
                .opacity(isRefreshing ? 1 : progress.fraction)
                .symbolEffect(.rotate, isActive: isRefreshing)
                .padding(10)
                .glassEffect(in: .circle)
                .padding(.bottom, 12)
                .accessibilityIdentifier("pull-up-refresh")
                .accessibilityLabel(Text("Refresh", bundle: .module))
                .allowsHitTesting(false)
                .animation(.snappy(duration: 0.2), value: progress)
                .animation(.snappy, value: isRefreshing)
        }
    }

    private func refresh() {
        isRefreshing = true
        Task {
            // A spinner that flashes up for a frame reads as a glitch, so it
            // stays long enough to be seen even when the reply comes back at
            // once from the cache.
            async let minimumShowing: Void? = try? await Task.sleep(for: .milliseconds(700))
            await action()
            _ = await minimumShowing
            isRefreshing = false
        }
    }
}

extension View {
    /// Adds "pull up past the end to refresh" to a scrolling view.
    func pullUpToRefresh(action: @escaping () async -> Void) -> some View {
        modifier(PullUpToRefreshModifier(action: action))
    }
}
