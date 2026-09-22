import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia
import Observation
import SwiftUI

/// Something that can fetch the head of a clip ahead of time.
///
/// A seam only so a test can watch what the feed asks for; the app always
/// hands over the real prefetcher.
public protocol MediaWarming: Sendable {
    func warm(_ url: URL, referer: URL?) async
    func cancelAll() async
}

/// Fetches the rest of the clip on screen while it plays.
///
/// Separate from `MediaWarming` because the two want opposite things: warming
/// gives way the moment the clip on screen needs bytes, and this is the clip on
/// screen. Behind a protocol so a test can watch what the viewer asks for
/// without a network.
public protocol MediaCompleting: Sendable {
    func complete(_ url: URL, referer: URL?, onProgress: (@Sendable (Double) -> Void)?) async
    func cancel(_ url: URL) async
    func cancelAll() async
}

extension MediaCompleter: MediaCompleting {}

extension MediaPrefetcher: MediaWarming {
    public func warm(_ url: URL, referer: URL?) async {
        await warm(url, referer: referer, bytes: Self.defaultWarmBytes)
    }
}

/// Drives the feed of a thread's videos.
///
/// One player for the whole mode, whose URL is swapped as the reader pages —
/// never a player per clip. The engine's choices are global to the process and
/// read when a player is built, every player claims the audio session for
/// itself, and every player resumes itself after a phone call. Several at once
/// means whichever is built last decides how the one on screen is decoded, the
/// first to scroll away silences the one still playing, and a call leaves two
/// clips playing where nobody can see them.
///
/// The items are a snapshot. A thread that gains videos while this is open does
/// not grow, exactly as the gallery does not.
@MainActor
@Observable
public final class DoomscrollViewModel {
    /// Every video in the thread, in reading order.
    public let items: [GalleryItem]

    /// The clip the player is on. Moves only when scrolling settles.
    public private(set) var playingID: GalleryItem.ID?
    /// False while a drag is in progress, when the posters cover the player.
    public private(set) var isSettled = true

    /// Off at the start of every viewing.
    ///
    /// Deliberately not a stored preference and not remembered between
    /// openings: a feed that starts talking is the one thing a reader in public
    /// cannot undo in time.
    public private(set) var isMuted = true

    public var playbackState: PlaybackState = .idle
    public var playbackProgress = PlaybackProgress()
    public var playbackControl = PlaybackControl()

    /// Saving and sharing, shared with the gallery.
    public let transfers: MediaTransferController

    private let services: AppServices
    private let warmer: any MediaWarming
    /// The cookies the media host expects, read once — the jar does not change
    /// while a feed is on screen.
    private let sessionCookies: [String: String]
    @ObservationIgnored private var cachedOptions: [MediaKind: MediaPlayerOptions] = [:]
    /// What has been asked for, so the same clip is not asked for twice.
    @ObservationIgnored private var warmedID: GalleryItem.ID?

    public init(
        items: [GalleryItem],
        startIndex: Int = 0,
        services: AppServices,
        warmer: (any MediaWarming)? = nil,
        transfers: MediaTransferController? = nil,
        cookieProvider: ((DvachDomain) -> [String: String])? = nil
    ) {
        // Only what the player can actually open, and only what resolves to a
        // URL, so nothing downstream has to cope with a clip that cannot load.
        let site = services.settings.siteSelection
        self.items = items.filter { item in
            item.isVideo && SiteEndpoints(site).url(forPath: item.attachment.path) != nil
        }
        self.services = services
        self.warmer = warmer ?? MediaPrefetcher.shared
        // A clip that runs out of bytes wants the connection to itself, so
        // whatever is being read ahead for a later one is dropped at once
        // rather than at the end of the block it happened to be fetching.
        PlaybackDemand.whenPlaybackStartsWaiting {
            Task { await MediaPrefetcher.shared.cancelAll() }
        }
        self.transfers = transfers ?? MediaTransferController(services: services)
        self.sessionCookies = (cookieProvider ?? Self.storedCookies)(services.settings.domain)
        self.playingID = self.items.indices.contains(startIndex)
            ? self.items[startIndex].id
            : self.items.first?.id
    }

    public var currentItem: GalleryItem? {
        items.first { $0.id == playingID }
    }

    /// `3 / 12`, the way the gallery says it.
    public var positionText: String {
        guard let playingID, let index = items.firstIndex(where: { $0.id == playingID })
        else { return "" }
        return "\(index + 1) / \(items.count)"
    }

    public func url(for item: GalleryItem) -> URL? {
        SiteEndpoints(services.settings.siteSelection).url(forPath: item.attachment.path)
    }

    /// What the media host expects as the page the file was linked from.
    public var referer: URL? {
        SiteEndpoints(services.settings.siteSelection).web
    }

    /// How the one player is configured.
    ///
    /// Looping and autoplay are forced on and the reader's own preferences for
    /// them are not consulted: a feed that does not play by itself, or that
    /// stops at the end of every clip, is not this feature.
    public func playerOptions(for item: GalleryItem) -> MediaPlayerOptions {
        if let cached = cachedOptions[item.kind] { return cached }
        let options = MediaPlayerOptions(
            kind: item.kind,
            referer: referer,
            userAgent: UserAgent.current,
            cookies: sessionCookies,
            loops: true,
            autoplays: true,
            startsMuted: isMuted
        )
        cachedOptions[item.kind] = options
        return options
    }

    // MARK: Paging

    /// The reader has started dragging.
    ///
    /// The clip stops here rather than when the next one arrives, so a scroll
    /// through six videos plays none of them.
    public func beganScrolling() {
        guard isSettled else { return }
        isSettled = false
        playbackControl.send(.pause)
    }

    /// The scroll has come to rest on a clip.
    public func settled(on id: GalleryItem.ID?) {
        isSettled = true
        guard let id, items.contains(where: { $0.id == id }) else {
            playbackControl.send(.play)
            return
        }
        if id != playingID {
            playingID = id
            playbackState = .preparing
        }
        playbackControl.send(.play)
    }

    // MARK: Playback

    /// Takes the player's state, and uses it as the cue to warm the next clip.
    public func playbackStateChanged(_ state: PlaybackState) {
        playbackState = state
        guard state == .playing else { return }

        // Re-sent on every start. `startsMuted` reaches the engine through an
        // optional chain that quietly does nothing when the layer is not built
        // yet, and the cost of it being dropped once is the app making a noise
        // the reader asked it not to.
        playbackControl.send(.setMuted(isMuted))
        warmNextClip()
    }

    public func toggleMute() {
        isMuted.toggle()
        playbackControl.send(.setMuted(isMuted))
        // The options carry the initial mute, so they stop being right.
        cachedOptions.removeAll(keepingCapacity: true)
    }

    // MARK: Saving and sharing

    public func saveCurrentItem() {
        guard let item = currentItem, let url = url(for: item) else { return }
        transfers.save(item, at: url)
    }

    public func fileForSharing() async -> URL? {
        guard let item = currentItem, let url = url(for: item) else { return nil }
        return await transfers.fileForSharing(item, at: url)
    }

    // MARK: Lifecycle

    /// The app is going away. The engine pauses itself on the way out, but
    /// nothing starts it again on the way back.
    public func suspend() {
        playbackControl.send(.pause)
        Task { [warmer] in await warmer.cancelAll() }
    }

    public func resume() {
        // Only the player's own initialiser claims the session, so one that is
        // being reused comes back to a session nobody re-activated.
        MediaAudioSession.claim()
        playbackControl.send(.play)
        playbackControl.send(.setMuted(isMuted))
    }

    /// Called as the mode closes.
    ///
    /// The blocks a feed leaves behind are the ones nothing else prunes: only
    /// the whole-file cache and a trip to the background evict, and this is the
    /// first screen that writes blocks at speed for clips nobody finishes.
    /// The one player the feed shows, owned here so it stops when the feed
    /// does rather than when its view is told it has gone, which a view is
    /// not always told.
    public let player = MediaPlayer()

    public func finish() {
        player.shutdown()
        Task { [warmer] in
            await warmer.cancelAll()
            await MediaCache.shared.evictIfNeeded()
        }
    }

    // MARK: Warming

    private func warmNextClip() {
        guard DoomscrollPolicy.mayWarm(
            isPlaying: playbackState == .playing,
            allowsMediaLoading: services.allowsMediaLoading
        ) else { return }

        guard let playingID,
              let nextID = DoomscrollPolicy.clipToWarm(after: playingID, in: items.map(\.id)),
              nextID != warmedID,
              let next = items.first(where: { $0.id == nextID }),
              let url = url(for: next)
        else { return }

        warmedID = nextID
        Task { [warmer, referer] in await warmer.warm(url, referer: referer) }
    }

    private static func storedCookies(for domain: DvachDomain) -> [String: String] {
        let jar = HTTPCookieStorage.shared
        let cookies = jar.cookies(for: domain.baseURL) ?? []
        return Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
