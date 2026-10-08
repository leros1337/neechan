import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// Full-screen viewer for a thread's attachments.
///
/// The controls float on glass over the media, which is the one place the HIG
/// calls for the clear variant: it sits directly on content, with a dimming
/// gradient behind it so text stays legible over a bright image.
public struct GalleryView: View {
    @State private var model: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    @State private var browserLink: BrowserLink?
    /// How far the reader has dragged the viewer down to close it.
    @State private var dragOffset: CGFloat = 0
    /// Set while the picture on screen is magnified, where a drag belongs to
    /// the picture rather than to the viewer.
    @State private var isZoomedIn = false
    /// What Live Text found in the picture on screen, and whether the reader
    /// has the text lifted out, where a drag selects words rather than
    /// closing the viewer.
    @State private var liveText = LiveTextStatus()

    /// Called with a post number when the reader asks to go to it.
    ///
    /// The gallery cannot scroll the thread itself: it is presented over it,
    /// so it hands the number back to whoever opened it and closes.
    private let onGoToPost: ((Int) -> Void)?
    /// Handed down to the pages explicitly rather than left to be inherited.
    ///
    /// The gallery is presented as a cover, and an iPad build running on a Mac
    /// builds a cover's pages before the presenter's environment reaches them:
    /// a page's `@Environment(AppServices.self)` found nothing and trapped the
    /// moment the gallery opened.
    private let services: AppServices

    public init(
        items: [GalleryItem],
        startIndex: Int,
        services: AppServices,
        onGoToPost: ((Int) -> Void)? = nil
    ) {
        _model = State(initialValue: GalleryViewModel(
            items: items, startIndex: startIndex, services: services
        ))
        self.onGoToPost = onGoToPost
        self.services = services
    }

    public var body: some View {
        content.environment(services)
    }

    private var content: some View {
        ZStack {
            // Behind the arrangement rather than inside it, so that a folded
            // display with the chrome hidden is black on both planes instead
            // of black on one and nothing on the other.
            Color.black.ignoresSafeArea()

            DuoArrangement(.overlay) {
                chrome
            } secondary: {
                pages
            }
        }
        // Alongside the tap and the paging rather than instead of them: a
        // sideways drag is still paging, and this only takes an interest once
        // the drag is clearly downward.
        .simultaneousGesture(closeDrag)
        .animation(.snappy(duration: 0.2), value: model.transfer)
        // The tick clears itself once it has been on screen long enough to read.
        .task(id: model.transfer?.isFinished) {
            guard model.transfer?.isFinished == true else { return }
            await model.clearFinishedTransfer()
        }
        .hidesStatusBar(!model.areControlsVisible)
        .sheet(item: Binding(
            get: { shareURL.map(ShareTarget.init) },
            set: { shareURL = $0?.url }
        )) { target in
            ShareSheet(items: [target.url])
        }
        .internalBrowser(link: $browserLink)
        // A short tap when a video finishes saving, which is the one action here
        // the reader starts and then looks away from. Nothing is played for an
        // image, which saves too quickly to be worth announcing, nor for a save
        // the reader cancelled. Cross-platform by construction: this does
        // nothing where there is no Taptic Engine.
        .sensoryFeedback(trigger: model.lastVideoSave) { _, outcome in
            SaveHaptic.feedback(for: outcome)
        }
        // Only failures interrupt: a save that worked says so in the capsule.
        .alert(item: $model.saveResult) { result in
            Alert(
                title: Text("Could not save", bundle: .module),
                message: Text(result.message),
                dismissButton: .default(Text("OK", bundle: .module))
            )
        }
    }

    /// The files, one per page, swiped between sideways.
    ///
    /// Its own property rather than part of the body: with the drag to close
    /// added inline, the whole body became one expression the compiler would
    /// not finish type-checking.
    private var pages: some View {
        TabView(selection: $model.currentIndex) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                page(at: index, item: item).tag(index)
            }
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
        .ignoresSafeArea()
        // A drag across lifted-out text is selecting it, not turning the page.
        .scrollDisabled(liveText.isHighlighted)
        // Follows the finger on the way out, and shrinks a little as it goes,
        // so the drag reads as putting the file down rather than as the screen
        // glitching.
        .offset(y: dragOffset)
        .scaleEffect(1 - min(0.12, dragOffset / 2600))
        .onChange(of: model.currentIndex) { _, _ in
            model.resetPlayback()
            // A new page is never zoomed, and the one left behind stops having
            // a say in the gesture.
            isZoomedIn = false
            liveText = LiveTextStatus()
        }
        .onDisappear { model.finishPlayback() }
        // The background only: a glance at the app switcher or Control Centre
        // leaves the clip playing. Nothing happens on the way back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.appDidEnterBackground() }
        }
    }

    private func page(at index: Int, item: GalleryItem) -> some View {
        GalleryPage(
            item: item,
            url: model.url(for: item),
            playerOptions: model.playerOptions(for: item),
            player: model.player,
            isCurrent: index == model.currentIndex,
            onSingleTap: { model.toggleControls() },
            onGoToPost: onGoToPost.map { goToPost in
                {
                    dismiss()
                    goToPost(item.postNum)
                }
            },
            onSave: { model.saveCurrentItem() },
            onShare: { share() },
            onReverseSearch: { openOffSite($0, settings: services.settings, in: $browserLink) },
            onZoomChanged: { zoomed in
                // Only the page being looked at has a say: the ones either side
                // report as they are built.
                guard index == model.currentIndex else { return }
                isZoomedIn = zoomed
            },
            isLiveTextHighlighted: index == model.currentIndex && liveText.isHighlighted,
            onLiveTextChanged: { status in
                guard index == model.currentIndex else { return }
                liveText = status
            },
            playbackState: $model.playbackState,
            // Written, never read, here: only the scrubber reads it, so only
            // the scrubber redraws as the clip plays.
            onProgress: { [model] in model.playbackProgress = $0 },
            playbackControl: $model.playbackControl
        )
    }

    /// Dragging the viewer down closes it.
    ///
    /// The close button is easy to miss on a phone held one-handed, and every
    /// other full-screen picture on the device is put away this way.
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                // A magnified picture owns its own drags: the reader is moving
                // it around, not putting it away.
                guard !isZoomedIn, !liveText.isHighlighted else { return }
                // Downward and more down than across, or this would fight the
                // swipe between files.
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width)
                else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard dragOffset > 0 else { return }
                // A flick counts as well as a long pull: the gesture is a
                // throw, and waiting for 140 points of it feels stuck.
                let flicked = value.predictedEndTranslation.height > 420
                if dragOffset > 140 || flicked {
                    dismiss()
                } else {
                    withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                }
            }
    }

    /// Downloads the file and hands it to the share sheet.
    private func share() {
        Task {
            isPreparingShare = true
            shareURL = await model.fileForSharing()
            isPreparingShare = false
        }
    }

    // MARK: Chrome

    /// Everything drawn over the file: the two bars, and the save capsule.
    ///
    /// Gathered into one view because on a part-folded iPhone Duo it becomes
    /// the other half of an arrangement -- the file on one plane of the
    /// display, what acts on it on the other. It stays in the tree whether or
    /// not anything is showing, so that hiding the chrome cannot rebuild the
    /// pages underneath and lose the reader's place and zoom.
    private var chrome: some View {
        ZStack {
            if model.areControlsVisible {
                controls
                    .transition(.opacity)
            }

            if let transfer = model.transfer {
                VStack {
                    Spacer()
                    TransferCapsule(transfer: transfer, batch: model.transfers.batch) { model.cancelTransfer() }
                        // Clear of the transport, which owns the bottom strip.
                        .padding(.bottom, model.areControlsVisible ? 56 : 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Label {
                    Text("Close", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)

            // Two flexible spacers, so the card centres in the gap between the
            // two fixed elements. Neither the button nor the counter compresses,
            // which leaves the card the only child that can give up width: a
            // long name shrinks the card rather than shoving the counter off.
            Spacer(minLength: 8)

            if let item = model.currentItem {
                GalleryCaption(item: item)
            }

            Spacer(minLength: 8)

            Text(model.positionText)
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // The outer front camera is always there, in a corner, and this bar
        // runs the full width past it. Inset the controls rather than the
        // gradient, which should still reach the edge.
        .duoAvoidingOcclusions()
        .background {
            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    /// One control stack: the scrubber on its own full-width row when there is
    /// a video, then the actions. Keeping the scrubber off the button row is
    /// what makes it big enough to actually drag.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Each of these reads playback state, which the engine reports ten
            // times a second. They are separate views so that those reports
            // invalidate a button rather than the whole gallery: this body
            // builds a page for every attachment in the thread, and a thread
            // can hold eighty of them.
            if model.isShowingVideo {
                ScrubberRow(model: model)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    if model.isShowingVideo {
                        PlayPauseButton(model: model)
                        MuteButton(model: model)
                        LoopControl(model: model)
                    }

                    Spacer(minLength: 0)

                    if !model.isShowingVideo, liveText.isAvailable {
                        LiveTextButton(isHighlighted: $liveText.isHighlighted)
                    }

                    Button {
                        model.saveCurrentItem()
                    } label: {
                        Label {
                            Text("Save", bundle: .module)
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)

                    Button {
                        share()
                    } label: {
                        Label {
                            Text("Share", bundle: .module)
                        } icon: {
                            Image(systemName: isPreparingShare
                                  ? "ellipsis" : "square.and.arrow.up")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .disabled(isPreparingShare)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

/// Lifts the text out of the picture, so it can be selected, copied or
/// looked up, or puts it back.
///
/// Offered only where Live Text found something, so a photo of a cat does
/// not carry a button that does nothing.
private struct LiveTextButton: View {
    @Binding var isHighlighted: Bool

    var body: some View {
        Button {
            isHighlighted.toggle()
        } label: {
            Label {
                Text("Live Text", bundle: .module)
            } icon: {
                Image(systemName: "text.viewfinder")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .tint(isHighlighted ? Color.accentColor : nil)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("live-text")
    }
}

/// The scrubber, and nothing else that would be redrawn with it.
private struct ScrubberRow: View {
    let model: GalleryViewModel

    var body: some View {
        PlaybackScrubber(
            fraction: model.playbackProgress.fraction,
            bufferedFraction: model.bufferedFraction,
            isSeekable: model.playbackProgress.isSeekable,
            timeLabel: model.timeLabel,
            isBusy: model.playbackState.isBusy,
            onSeek: { model.seek(toFraction: $0) },
            preview: model.scrubbing,
            fallback: model.currentItem?.attachment,
            onScrub: { fraction in
                if let fraction {
                    model.scrub(to: fraction)
                } else {
                    model.endScrub()
                }
            }
        ) {
            FrameStepButtons(model: model)
            SpeedMenu(model: model)
        }
    }
}

/// One picture back, one picture on, while the clip is stopped.
///
/// Only then: on a running clip a picture is gone before the finger is off
/// the glass. Its own view so it reads the playback state and nothing else.
private struct FrameStepButtons: View {
    let model: GalleryViewModel

    var body: some View {
        switch model.playbackState {
        case .paused, .finished:
            HStack(spacing: 2) {
                step(forward: false)
                step(forward: true)
            }
        default:
            EmptyView()
        }
    }

    private func step(forward: Bool) -> some View {
        Button {
            model.stepFrame(forward: forward)
        } label: {
            Label {
                if forward {
                    Text("Next frame", bundle: .module)
                } else {
                    Text("Previous frame", bundle: .module)
                }
            } icon: {
                Image(systemName: forward ? "forward.frame.fill" : "backward.frame.fill")
            }
            .labelStyle(.iconOnly)
            .font(.caption)
            .frame(width: 32, height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .buttonRepeatBehavior(.enabled)
        .accessibilityIdentifier(forward ? "next-frame" : "previous-frame")
    }
}

/// The speed the clip plays at, under the scrubber.
///
/// Its own view so the ten-a-second progress reports that redraw the scrubber
/// leave it alone: it reads the speed and nothing else.
private struct SpeedMenu: View {
    let model: GalleryViewModel

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { model.playbackRate },
                set: { model.playbackRate = $0 }
            )) {
                ForEach(GalleryViewModel.playbackRates, id: \.self) { rate in
                    Text(verbatim: Self.label(for: rate)).tag(rate)
                }
            } label: {
                Text("Playback speed", bundle: .module)
            }
        } label: {
            Text(verbatim: Self.label(for: model.playbackRate))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(model.playbackRate == 1 ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text("Playback speed", bundle: .module))
        .accessibilityValue(Text(verbatim: Self.label(for: model.playbackRate)))
        .accessibilityIdentifier("playback-speed")
    }

    /// `1×`, `0,75×`: in the app's own way of writing numbers.
    static func label(for rate: Float) -> String {
        Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(AppLocale.current)) + "×"
    }
}

private struct PlayPauseButton: View {
    let model: GalleryViewModel

    var body: some View {
        Button { model.togglePlayback() } label: {
            Label {
                Text(model.playbackState.isPlaying ? "Pause" : "Play", bundle: .module)
            } icon: {
                Image(systemName: model.playbackState.isPlaying ? "pause.fill" : "play.fill")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
    }
}

private struct MuteButton: View {
    let model: GalleryViewModel

    var body: some View {
        Button { model.toggleMuted() } label: {
            Label {
                Text(model.isMuted ? "Unmute" : "Mute", bundle: .module)
            } icon: {
                Image(systemName: model.isMuted
                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
    }
}

private struct LoopControl: View {
    let model: GalleryViewModel

    var body: some View {
        LoopButton(isOn: model.isLooping) { model.toggleLooping() }
    }
}

/// Repeat the clip when it ends.
///
/// Off by default: most clips are watched once, and a loop the reader did not
/// ask for is hard to escape. Tinted while on, so the state reads at a glance
/// without a second icon to learn.
private struct LoopButton: View {
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Group {
            if isOn {
                Button(action: action) { icon }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { icon }
                    .buttonStyle(.glass)
            }
        }
        .accessibilityLabel(Text("Loop", bundle: .module))
        .accessibilityValue(isOn ? Text("On", bundle: .module) : Text("Off", bundle: .module))
    }

    private var icon: some View {
        Image(systemName: "repeat")
    }
}

/// The playback position, on its own full-width row.
///
/// Hand-built rather than a `Slider`, which only responds to dragging its thumb.
/// A tap anywhere on the track jumps there, which is what a video scrubber is
/// expected to do.
private struct PlaybackScrubber<Accessory: View>: View {
    let fraction: Double
    /// How much of the file is on disk, 0 to 1: the dimmed bar behind the
    /// playhead. Bytes rather than seconds, so it is a close approximation
    /// rather than an exact one, which is what every player's buffer bar is.
    let bufferedFraction: Double
    let isSeekable: Bool
    let timeLabel: String
    let isBusy: Bool
    var onSeek: (Double) -> Void
    /// The picture for where the finger is, while it is on the track.
    var preview: GalleryViewModel.ScrubPreview?
    /// The post's own thumbnail, for where there is no picture yet.
    var fallback: NeechanAPI.Attachment?
    /// Where the finger is on the track, or nil once it has let go.
    var onScrub: (Double?) -> Void = { _ in }
    /// Controls at the end of the time row, opposite the time.
    @ViewBuilder var accessory: Accessory

    /// Where the thumb is while the finger is down, before the seek commits.
    @State private var dragFraction: Double?

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 20
    /// The track is thin; the touch area is not.
    private let touchHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 6) {
            if isSeekable {
                track
                    .accessibilityIdentifier("playback-scrubber")
                    .accessibilityLabel(Text("Playback position", bundle: .module))
                    .accessibilityValue(Text(timeLabel))
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .opacity(isBusy ? 1 : 0.35)
                    .frame(height: touchHeight)
            }

            HStack {
                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shown = dragFraction ?? fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: trackHeight)

                // How much can be watched without waiting. Behind the played
                // part, so the two read as one bar filling up rather than as
                // two things racing.
                Capsule()
                    .fill(.tertiary)
                    .frame(width: width * clamp(bufferedFraction), height: trackHeight)
                    // Blocks land a megabyte at a time; unanimated, the bar
                    // jumps in visible steps.
                    .animation(.easeOut(duration: 0.25), value: bufferedFraction)

                Capsule()
                    .fill(.tint)
                    .frame(width: width * shown, height: trackHeight)

                Circle()
                    .fill(.white)
                    .shadow(radius: 1, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: (width * shown) - thumbSize / 2)
            }
            .frame(height: proxy.size.height, alignment: .center)
            // The whole strip is the target, not just the thumb.
            .contentShape(.rect)
            .gesture(
                // A zero minimum distance makes a plain tap count as a drag, so
                // tapping the track seeks instead of doing nothing.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = clamp(value.location.x / width)
                        dragFraction = fraction
                        onScrub(fraction)
                    }
                    .onEnded { value in
                        let target = clamp(value.location.x / width)
                        dragFraction = nil
                        onScrub(nil)
                        onSeek(target)
                    }
            )
            .overlay(alignment: .bottomLeading) {
                // Above the thumb, kept inside the track's ends so it is never
                // cut off at the edge of the screen.
                if let preview, dragFraction != nil {
                    ScrubPreviewBubble(preview: preview, fallback: fallback)
                        .offset(
                            x: min(max(0, width * shown - ScrubPreviewBubble.width / 2), max(0, width - ScrubPreviewBubble.width)),
                            y: -(touchHeight + 8)
                        )
                        .transition(.opacity)
                }
            }
        }
        .frame(height: touchHeight)
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

/// The picture for where the finger is on the scrubber, and when that is.
///
/// The post's own thumbnail stands in where the clip has not arrived yet:
/// the previews come only from what is already on the device.
private struct ScrubPreviewBubble: View {
    static let width: CGFloat = 136

    let preview: GalleryViewModel.ScrubPreview
    let fallback: NeechanAPI.Attachment?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if let fallback {
                    ThumbnailView(attachment: fallback, side: nil)
                } else {
                    Color.black
                }
            }
            .frame(width: Self.width - 8, height: (Self.width - 8) * 9 / 16)
            .background(.black)
            .clipShape(.rect(cornerRadius: 8))

            Text(verbatim: VideoDuration.label(seconds: Int(preview.seconds)))
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .padding(4)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// File name, size and dimensions for the item on screen, shown in the top bar
/// between the close button and the position counter.
private struct GalleryCaption: View {
    let item: GalleryItem

    var body: some View {
        VStack(spacing: 2) {
            Text(item.attachment.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                // The card is width-constrained here, and truncating the tail
                // would eat the extension, which is the part that says what the
                // file actually is.
                .truncationMode(.middle)
            HStack(spacing: 6) {
                if let dimensions = item.formattedDimensions {
                    Text(dimensions)
                }
                Text(item.formattedSize)
                if let duration = item.attachment.durationText {
                    Text(duration)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        // One element among the buttons it now shares a row with, rather than
        // two separate texts for VoiceOver to step through.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gallery-info")
    }
}

/// Identifiable wrapper so the share sheet can be driven by a file URL.
private struct ShareTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }

    init(_ url: URL) {
        self.url = url
    }
}

#if os(iOS)
/// Bridges `UIActivityViewController`, which SwiftUI's ShareLink cannot replace
/// here because the file is downloaded only when the reader asks to share.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View {
    let items: [Any]
    var body: some View { EmptyView() }
}
#endif
