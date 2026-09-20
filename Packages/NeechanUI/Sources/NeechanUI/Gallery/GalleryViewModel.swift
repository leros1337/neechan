import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia
import Observation
import SwiftUI

/// Drives the full-screen gallery.
@MainActor
@Observable
public final class GalleryViewModel {
    public let items: [GalleryItem]
    public var currentIndex: Int
    /// Chrome is hidden on a single tap so the media fills the screen.
    public var areControlsVisible = true

    /// Saving and sharing, which a second screen needed too.
    ///
    /// Held rather than inherited so the gallery's own surface is unchanged:
    /// everything below forwards, and the views and tests that drive them did
    /// not have to learn a new shape.
    public let transfers: MediaTransferController

    public typealias Transfer = MediaTransferController.Transfer
    public typealias SaveResult = MediaTransferController.SaveResult
    public typealias VideoSaveOutcome = MediaTransferController.VideoSaveOutcome

    public var transfer: Transfer? { transfers.transfer }
    public var lastVideoSave: VideoSaveOutcome? { transfers.lastVideoSave }
    public var saveResult: SaveResult? {
        get { transfers.saveResult }
        set { transfers.saveResult = newValue }
    }

    /// Saves the file on screen, to Photos or to the folder the reader picked.
    public func saveCurrentItem() {
        guard let item = currentItem, let url = url(for: item) else { return }
        transfers.save(item, at: url)
    }

    /// Stops whatever is in flight and clears the capsule.
    public func cancelTransfer() {
        transfers.cancelTransfer()
    }

    /// Downloads the file on screen and returns it for the share sheet.
    public func fileForSharing() async -> URL? {
        guard let item = currentItem, let url = url(for: item) else { return nil }
        return await transfers.fileForSharing(item, at: url)
    }

    public func clearFinishedTransfer() async {
        await transfers.clearFinishedTransfer()
    }

    // Playback state for the page on screen. It lives here rather than inside
    // the page so the transport can sit in one control stack with the gallery's
    // own actions, instead of two bars fighting for the same strip of screen.
    public var playbackState: PlaybackState = .idle {
        // The moment the clip on screen is playing is the moment the
        // connection has room for the next one.
        didSet { if playbackState == .playing { warmNextVideo() } }
    }
    public var playbackProgress = PlaybackProgress()
    public var playbackControl = PlaybackControl()
    public var isMuted = false
    /// Repeat the clip when it ends. Starts from the preference, and the button
    /// in the transport changes it for this viewing only.
    public var isLooping = false {
        // The cached options carry the loop flag, so they stop being right the
        // moment the reader changes it.
        didSet { cachedOptions.removeAll(keepingCapacity: true) }
    }

    private let services: AppServices
    /// Fetches the head of the next clip while this one plays. The same one
    /// the feed uses, so the two never fetch ahead against each other.
    private let warmer: any MediaWarming = MediaPrefetcher.shared
    /// What has been asked for, so paging back and forth does not ask again.
    @ObservationIgnored private var warmedID: GalleryItem.ID?

    /// The cookies the media host expects, read once when the gallery opens.
    ///
    /// The jar does not change while a gallery is on screen, and asking it was
    /// not free: the player options were rebuilt for every attachment in the
    /// thread on every pass of the gallery's body, and the body ran whenever
    /// playback reported progress, ten times a second.
    private let sessionCookies: [String: String]
    /// Player options per kind of file, built on demand and kept.
    @ObservationIgnored private var cachedOptions: [MediaKind: MediaPlayerOptions] = [:]

    public init(
        items: [GalleryItem],
        startIndex: Int,
        services: AppServices,
        downloader: (any MediaDownloading)? = nil,
        cache: MediaCache = .shared,
        blocks: MediaBlockStore = .shared,
        cookieProvider: ((DvachDomain) -> [String: String])? = nil
    ) {
        self.items = items
        self.currentIndex = min(max(0, startIndex), max(0, items.count - 1))
        self.services = services
        self.transfers = MediaTransferController(
            services: services, downloader: downloader, cache: cache, blocks: blocks
        )
        self.isLooping = services.settings.videoLoops
        let domain = services.settings.domain
        self.sessionCookies = (cookieProvider ?? GalleryViewModel.storedCookies)(domain)
    }

    public var currentItem: GalleryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    /// Position shown in the title, one-based.
    public var positionText: String {
        guard !items.isEmpty else { return "" }
        return "\(currentIndex + 1) / \(items.count)"
    }

    /// True when the page on screen is a video, so the transport is shown.
    public var isShowingVideo: Bool {
        currentItem?.isVideo == true
    }

    public func togglePlayback() {
        playbackControl.send(playbackState.isPlaying ? .pause : .play)
    }

    public func toggleMuted() {
        isMuted.toggle()
        playbackControl.send(.setMuted(isMuted))
    }

    public func toggleLooping() {
        isLooping.toggle()
        playbackControl.send(.setLooping(isLooping))
    }

    public func seek(toFraction fraction: Double) {
        guard playbackProgress.isSeekable else { return }
        playbackControl.send(.seek(fraction * playbackProgress.total))
    }

    /// `0:07 / 0:23`, or empty when the clip reports no duration.
    public var timeLabel: String {
        guard playbackProgress.isSeekable else { return "" }
        let format = Duration.TimeFormatStyle(pattern: .minuteSecond)
        let current = Duration.seconds(Int(playbackProgress.current)).formatted(format)
        let total = Duration.seconds(Int(playbackProgress.total)).formatted(format)
        return "\(current) / \(total)"
    }

    /// Resets playback when the reader pages to another file.
    ///
    /// The loop choice is deliberately kept: having turned it on, a reader
    /// expects the next clip to loop too.
    public func resetPlayback() {
        playbackState = .idle
        playbackProgress = PlaybackProgress()
        playbackControl = PlaybackControl()
        // Leaving a video for a still: nothing is going to load another clip
        // into the player, so it is stopped here. Video to video is handled
        // by the next page loading its clip, which replaces this one.
        if currentItem?.isVideo != true { player.unload() }
    }

    /// The one player every video page shows.
    ///
    /// Owned here rather than by the page, because the pager is not reliable
    /// about a page's lifetime: it builds two views for the page it lands on
    /// and never tells the spare one it has gone, so a player owned by a view
    /// went on playing, unseen, to the end of every clip swiped past. One
    /// player, loaded with whatever clip is on screen, cannot play two clips
    /// at once, and it stops when the gallery closes.
    public let player = MediaPlayer()

    /// The gallery is closing: the clip stops for good.
    public func finishPlayback() {
        player.shutdown()
    }

    public func toggleControls() {
        withAnimation(.snappy(duration: 0.2)) {
            areControlsVisible.toggle()
        }
    }

    /// Fetches the opening seconds of the next video along, so swiping to it
    /// lands on a picture rather than on a wait.
    ///
    /// Only while the clip on screen is already playing, so the two are not
    /// fetching against each other over one connection, and only the next
    /// video rather than the next page: stills between videos load in a moment
    /// and need no warming. Forward only, because that is the way a gallery is
    /// read; the prefetcher keeps one warm in flight, and a second would cancel
    /// the first.
    private func warmNextVideo() {
        guard DoomscrollPolicy.mayWarm(
            isPlaying: playbackState == .playing,
            allowsMediaLoading: services.allowsMediaLoading
        ) else { return }

        let after = items.index(after: currentIndex)
        guard after < items.endIndex,
              let next = items[after...].first(where: \.isVideo),
              next.id != warmedID,
              let url = url(for: next)
        else { return }

        warmedID = next.id
        let referer = referer(for: next)
        Task { [warmer] in await warmer.warm(url, referer: referer) }
    }

    /// Full-size URL for an item, resolved against its site's media host.
    public func url(for item: GalleryItem) -> URL? {
        item.endpoints(mirror: services.settings.domain).url(forPath: item.attachment.path)
    }

    /// The page the item's site expects its files to be linked from.
    public func referer(for item: GalleryItem) -> URL {
        item.endpoints(mirror: services.settings.domain).web
    }

    /// Options for the video player, carrying the headers the site expects.
    ///
    /// Memoised per kind of file. Everything in here is fixed for the life of
    /// the gallery except the loop flag, which clears the cache when it changes.
    public func playerOptions(for item: GalleryItem) -> MediaPlayerOptions {
        if let cached = cachedOptions[item.kind] { return cached }

        // One thread, one site: every item here shares a referer, so keying
        // the cache on the kind alone is safe.
        let options = MediaPlayerOptions(
            kind: item.kind,
            referer: referer(for: item),
            userAgent: UserAgent.current,
            cookies: sessionCookies,
            loops: isLooping,
            autoplays: services.settings.videoAutoplay
        )
        cachedOptions[item.kind] = options
        return options
    }

    private static func storedCookies(for domain: DvachDomain) -> [String: String] {
        let jar = HTTPCookieStorage.shared
        let cookies = jar.cookies(for: domain.baseURL) ?? []
        return Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
