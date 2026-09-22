import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// A thread's videos, one per screen, played as a feed.
///
/// The layering is load-bearing. One player sits at the bottom of the stack and
/// the paging scroll view sits over it with transparent cells, rather than a
/// player inside each cell. Two reasons, and either alone would decide it:
///
/// - the engine attaches its own swipe recognisers to the player's view, and a
///   swipe-up recogniser above a vertical feed eats the reader's drags at
///   random, which reads as a broken app rather than as a conflict;
/// - one player is the only way to keep the audio session, the decoder and the
///   engine's process-wide settings straight (see `DoomscrollViewModel`).
struct DoomscrollView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: DoomscrollViewModel
    /// Where the scroll view thinks it is. An input to the model, never a
    /// trigger: it moves mid-drag and can go briefly nil.
    @State private var scrolledID: GalleryItem.ID?
    @State private var isSharing = false
    @State private var shareURL: URL?

    /// Goes to the post the clip came from, closing the feed on the way.
    var onGoToPost: ((Int) -> Void)?

    init(items: [GalleryItem], startIndex: Int = 0, services: AppServices, onGoToPost: ((Int) -> Void)? = nil) {
        _model = State(
            initialValue: DoomscrollViewModel(
                items: items, startIndex: startIndex, services: services
            )
        )
        self.onGoToPost = onGoToPost
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.items.isEmpty {
                empty
            } else {
                // The clip and the controls over it, which a part-folded
                // display gives a plane each. The player and the feed are one
                // half between them: the feed is transparent and exists to
                // page the player underneath it, so they cannot be separated.
                DuoArrangement(.overlay) {
                    chrome
                } secondary: {
                    ZStack {
                        player
                        feed
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .hidesStatusBar(true)
        .animation(.snappy(duration: 0.2), value: model.transfers.transfer)
        // The tick clears itself once it has been on screen long enough to
        // read. Without this the capsule says "Saved" until the feed is closed.
        .task(id: model.transfers.transfer?.isFinished) {
            guard model.transfers.transfer?.isFinished == true else { return }
            await model.transfers.clearFinishedTransfer()
        }
        // A short tap when a video finishes saving. Saving a clip is the one
        // action here with a long, quiet middle — it downloads, often re-encodes,
        // and only then lands in Photos — by which time the reader is usually
        // watching the next clip rather than the capsule.
        .sensoryFeedback(trigger: model.transfers.lastVideoSave) { _, outcome in
            SaveHaptic.feedback(for: outcome)
        }
        .onAppear { scrolledID = model.playingID }
        .onDisappear { model.finish() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() } else { model.suspend() }
        }
        .sheet(isPresented: $isSharing) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .alert(item: Binding(
            get: { model.transfers.saveResult },
            set: { model.transfers.saveResult = $0 }
        )) { result in
            Alert(title: Text(result.message))
        }
    }

    /// The one player, behind everything.
    @ViewBuilder
    private var player: some View {
        if let item = model.currentItem, let url = model.url(for: item) {
            MediaPlayerView(
                player: model.player,
                url: url,
                options: model.playerOptions(for: item),
                state: Binding(get: { model.playbackState }, set: { model.playbackStateChanged($0) }),
                progress: $model.playbackProgress,
                control: $model.playbackControl,
                screen: "feed"
            )
            .ignoresSafeArea()
            // A swap is a new clip, not a new player: the id is deliberately
            // not the item's, so SwiftUI keeps this view and the engine reuses
            // its audio and video outputs.
            .id("doomscroll-player")
        }
    }

    private var feed: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    DoomscrollPage(
                        item: item,
                        isShowingVideo: item.id == model.playingID && model.isSettled,
                        onTap: { model.toggleMute() }
                    )
                    .containerRelativeFrame(.vertical)
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .onScrollPhaseChange { _, phase in
            if phase == .idle {
                model.settled(on: scrolledID)
            } else {
                model.beganScrolling()
            }
        }
    }

    // MARK: Chrome

    /// The controls, over everything.
    ///
    /// Only the bars themselves take touches: the gap between them is a
    /// `Spacer`, which draws nothing and so hit-tests nothing, leaving the feed
    /// underneath to receive the drags.
    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        // The outer front camera is always in the way of something here: this
        // draws edge to edge over a clip doing the same.
        .duoAvoidingOcclusions()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(Text("Close", bundle: .module))

            Spacer(minLength: 0)

            if let transfer = model.transfers.transfer {
                TransferCapsule(transfer: transfer) { model.transfers.cancelTransfer() }
            } else {
                Text(verbatim: model.positionText)
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(in: .capsule)
                    .accessibilityIdentifier("doomscroll-position")
            }

            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("doomscroll-sound")
            .accessibilityLabel(Text("Sound", bundle: .module))
            .accessibilityValue(model.isMuted ? Text("Off", bundle: .module) : Text("On", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let item = model.currentItem {
                Button {
                    dismiss()
                    onGoToPost?(item.postNum)
                } label: {
                    Text(verbatim: "№ \(item.postNum)")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("doomscroll-go-to-post")
                .accessibilityLabel(Text("Go to post", bundle: .module))
            }

            Spacer(minLength: 0)

            Button { model.saveCurrentItem() } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("doomscroll-save")
            .accessibilityLabel(Text("Save", bundle: .module))

            Button { share() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("doomscroll-share")
            .accessibilityLabel(Text("Share", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        // Says what the player is doing, for the tests: this mode has no
        // transport, so there is no button whose label proves a clip decoded.
        .background {
            Color.clear
                .accessibilityIdentifier("doomscroll-status")
                .accessibilityLabel(Text("Playback", bundle: .module))
                .accessibilityValue(Text(verbatim: Self.statusValue(model.playbackState)))
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label {
                Text("No videos in this thread", bundle: .module)
            } icon: {
                Image(systemName: "play.slash")
            }
        } description: {
            Text("Nothing in this thread has a video attached to it.", bundle: .module)
        } actions: {
            Button { dismiss() } label: {
                Text("Close", bundle: .module)
            }
        }
        .accessibilityIdentifier("doomscroll-empty")
    }

    private func share() {
        Task {
            shareURL = await model.fileForSharing()
            isSharing = shareURL != nil
        }
    }

    /// A plain word per state, so a test can wait on one.
    static func statusValue(_ state: PlaybackState) -> String {
        switch state {
        case .idle: "idle"
        case .preparing: "preparing"
        case .buffering: "buffering"
        case .playing: "playing"
        case .paused: "paused"
        case .finished: "finished"
        case .failed: "failed"
        }
    }
}
