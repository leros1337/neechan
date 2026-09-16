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
    @State private var shareURL: URL?
    @State private var isPreparingShare = false

    /// Called with a post number when the reader asks to go to it.
    ///
    /// The gallery cannot scroll the thread itself: it is presented over it,
    /// so it hands the number back to whoever opened it and closes.
    private let onGoToPost: ((Int) -> Void)?

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
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $model.currentIndex) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    GalleryPage(
                        item: item,
                        url: model.url(for: item),
                        playerOptions: model.playerOptions(for: item),
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
                        playbackState: $model.playbackState,
                        playbackProgress: $model.playbackProgress,
                        playbackControl: $model.playbackControl
                    )
                    .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .ignoresSafeArea()
            .onChange(of: model.currentIndex) { _, _ in
                model.resetPlayback()
            }

            if model.areControlsVisible {
                controls
                    .transition(.opacity)
            }

            if let transfer = model.transfer {
                VStack {
                    Spacer()
                    TransferCapsule(transfer: transfer) { model.cancelTransfer() }
                        // Clear of the transport, which owns the bottom strip.
                        .padding(.bottom, model.areControlsVisible ? 112 : 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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

    /// Downloads the file and hands it to the share sheet.
    private func share() {
        Task {
            isPreparingShare = true
            shareURL = await model.fileForSharing()
            isPreparingShare = false
        }
    }

    // MARK: Chrome

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

            Spacer(minLength: 0)

            Text(model.positionText)
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    /// One control stack: caption, then the scrubber on its own full-width row
    /// when there is a video, then the actions. Keeping the scrubber off the
    /// button row is what makes it big enough to actually drag.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let item = model.currentItem {
                GalleryCaption(item: item)
            }

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

/// The scrubber, and nothing else that would be redrawn with it.
private struct ScrubberRow: View {
    let model: GalleryViewModel

    var body: some View {
        PlaybackScrubber(
            fraction: model.playbackProgress.fraction,
            isSeekable: model.playbackProgress.isSeekable,
            timeLabel: model.timeLabel,
            isBusy: model.playbackState.isBusy,
            onSeek: { model.seek(toFraction: $0) }
        )
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
private struct PlaybackScrubber: View {
    let fraction: Double
    let isSeekable: Bool
    let timeLabel: String
    let isBusy: Bool
    var onSeek: (Double) -> Void

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
                        dragFraction = clamp(value.location.x / width)
                    }
                    .onEnded { value in
                        let target = clamp(value.location.x / width)
                        dragFraction = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: touchHeight)
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

/// File name, size and dimensions for the item on screen.
private struct GalleryCaption: View {
    let item: GalleryItem

    var body: some View {
        VStack(spacing: 2) {
            Text(item.attachment.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheet: View {
    let items: [Any]
    var body: some View { EmptyView() }
}
#endif
