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
    public var saveResult: SaveResult?

    /// What a save or a share is doing, or nil when nothing is in flight.
    ///
    /// Shown as a capsule over the media rather than as an alert at the end: a
    /// 20 MB clip on a slow connection used to look like a button that did
    /// nothing until it was suddenly finished.
    public private(set) var transfer: Transfer?

    // Playback state for the page on screen. It lives here rather than inside
    // the page so the transport can sit in one control stack with the gallery's
    // own actions, instead of two bars fighting for the same strip of screen.
    public var playbackState: PlaybackState = .idle
    public var playbackProgress = PlaybackProgress()
    public var playbackControl = PlaybackControl()
    public var isMuted = false
    /// Repeat the clip when it ends. Starts from the preference, and the button
    /// in the transport changes it for this viewing only.
    public var isLooping = false

    /// A save that did not work. A save that did is shown in the capsule.
    public struct SaveResult: Identifiable, Equatable {
        public let message: String
        public var id: String { message }

        public static func failed(_ message: String) -> SaveResult {
            SaveResult(message: message)
        }
    }

    /// A save or a share in flight.
    public struct Transfer: Equatable, Sendable {
        public enum Stage: Equatable, Sendable {
            case downloading
            /// A WebM being turned into something Photos will accept.
            case converting
            case saving
            case finished
        }

        public var stage: Stage
        /// 0...1 while the length is known, nil when the server did not say.
        public var fraction: Double?

        public var isFinished: Bool { stage == .finished }
    }

    private let services: AppServices
    private let downloader: any MediaDownloading
    /// The work behind `transfer`, kept so Cancel has something to stop.
    private var transferTask: Task<Void, Never>?
    /// When the last progress update was published.
    ///
    /// The downloader reports every 64 KB, which is some hundreds of times for
    /// a clip; redrawing that often costs more than the download does.
    private var lastProgressPublished = ContinuousClock.now

    public init(
        items: [GalleryItem],
        startIndex: Int,
        services: AppServices,
        downloader: (any MediaDownloading)? = nil
    ) {
        self.items = items
        self.currentIndex = min(max(0, startIndex), max(0, items.count - 1))
        self.services = services
        self.downloader = downloader ?? services.downloader
        self.isLooping = services.settings.videoLoops
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
    }

    public func toggleControls() {
        withAnimation(.snappy(duration: 0.2)) {
            areControlsVisible.toggle()
        }
    }

    /// Full-size URL for an item, resolved against the selected mirror.
    public func url(for item: GalleryItem) -> URL? {
        services.settings.domain.url(forPath: item.attachment.path)
    }

    /// Options for the video player, carrying the headers the site expects.
    public func playerOptions(for item: GalleryItem) -> MediaPlayerOptions {
        let domain = services.settings.domain
        return MediaPlayerOptions(
            kind: item.kind,
            referer: domain.baseURL,
            userAgent: UserAgent.current,
            cookies: cookies(for: domain),
            loops: isLooping,
            autoplays: services.settings.videoAutoplay
        )
    }

    /// Saves the current file, to Photos or to the folder the reader picked.
    ///
    /// Photos is the default because it needs no setup; a chosen folder is used
    /// as soon as there is one, and keeps the board and thread structure.
    public func saveCurrentItem() {
        guard transferTask == nil else { return }
        transferTask = Task { [weak self] in
            await self?.performSave()
            self?.transferTask = nil
        }
    }

    /// Stops whatever is in flight and clears the capsule.
    public func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        transfer = nil
    }

    private func performSave() async {
        guard let item = currentItem, let url = url(for: item) else { return }
        let settings = services.settings
        transfer = Transfer(stage: .downloading, fraction: 0)
        do {
            let downloaded = try await download(url, referer: settings.domain.baseURL)
            guard !Task.isCancelled else { return }
            let file = try await converted(downloaded, of: item)
            guard !Task.isCancelled else { return }
            transfer = Transfer(stage: .saving, fraction: nil)
            if !settings.savesToPhotos, let bookmark = settings.downloadFolderBookmark {
                try FileDownloadSaver.save(
                    fileAt: file,
                    named: Self.name(
                        for: item,
                        matching: file
                    ),
                    bookmark: bookmark,
                    subpath: DownloadPathTemplate.expand(
                        settings.downloadSubdirectoryPattern,
                        for: item.threadKey,
                        threadTitle: ""
                    ),
                    conflict: settings.downloadConflictAction
                )
            } else {
                defer { try? FileManager.default.removeItem(at: file) }
                try await PhotosSaver.save(fileAt: file, isVideo: item.isVideo)
            }
            finish()
        } catch FileDownloadSaver.SaveError.skipped {
            // Skipping is what the reader asked for, not a failure.
            finish()
        } catch is CancellationError {
            transfer = nil
        } catch Downloader.DownloadError.cancelled {
            transfer = nil
        } catch {
            transfer = nil
            saveResult = .failed(error.readableSaveMessage)
        }
    }

    /// Downloads the current file and returns it for the share sheet.
    public func fileForSharing() async -> URL? {
        guard let item = currentItem, let url = url(for: item) else { return nil }
        transfer = Transfer(stage: .downloading, fraction: 0)
        defer { transfer = nil }
        return try? await download(url, referer: services.settings.domain.baseURL)
    }

    /// Turns a WebM into an MP4, when that is what the reader asked for.
    ///
    /// Photos refuses a WebM outright, so for that destination a conversion
    /// that fails is a save that fails: sending the original on would only
    /// produce the same rejection with a worse message. A chosen folder takes
    /// the original happily, so there the failure is survivable.
    private func converted(_ file: URL, of item: GalleryItem) async throws -> URL {
        guard services.settings.convertsWebMOnSave, item.kind == .webmVideo else { return file }

        transfer = Transfer(stage: .converting, fraction: 0)
        let destination = file.deletingPathExtension().appendingPathExtension("mp4")
        do {
            try await WebMConverter().convert(fileAt: file, to: destination) { [weak self] fraction in
                Task { @MainActor in self?.publishConversion(fraction) }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if isSavingToPhotos { throw error }
            return file
        }
        // The WebM has served its purpose; leaving it behind fills the disk.
        try? FileManager.default.removeItem(at: file)
        return destination
    }

    private var isSavingToPhotos: Bool {
        services.settings.savesToPhotos || services.settings.downloadFolderBookmark == nil
    }

    /// The name to save under, carrying the extension of the file as it ended
    /// up rather than the one it arrived with.
    private static func name(for item: GalleryItem, matching file: URL) -> String {
        let name = DownloadNaming.fileName(
            for: item.attachment,
            in: item.threadKey,
            postNum: item.postNum,
            style: .detailed
        )
        let ending = file.pathExtension
        guard !ending.isEmpty, (name as NSString).pathExtension.lowercased() != ending.lowercased()
        else { return name }
        return (name as NSString).deletingPathExtension + "." + ending
    }

    private func publishConversion(_ fraction: Double) {
        guard transfer?.stage == .converting else { return }
        let now = ContinuousClock.now
        guard fraction >= 1 || now - lastProgressPublished > .milliseconds(100) else { return }
        lastProgressPublished = now
        transfer?.fraction = fraction
    }

    /// Fetches a file, keeping the capsule's fraction up to date.
    private func download(_ url: URL, referer: URL?) async throws -> URL {
        try await downloader.download(url, referer: referer) { [weak self] progress in
            Task { @MainActor in self?.publish(progress) }
        }
    }

    /// Takes a progress report, at most ten a second.
    private func publish(_ progress: Downloader.Progress) {
        guard transfer?.stage == .downloading else { return }
        let now = ContinuousClock.now
        let isComplete = progress.fraction.map { $0 >= 1 } ?? false
        guard isComplete || now - lastProgressPublished > .milliseconds(100) else { return }
        lastProgressPublished = now
        transfer?.fraction = progress.fraction
    }

    /// Ends the capsule on a tick, which clears itself.
    private func finish() {
        saveResult = nil
        transfer = Transfer(stage: .finished, fraction: 1)
    }

    /// Clears a finished capsule, after it has been on screen long enough to read.
    public func clearFinishedTransfer() async {
        try? await Task.sleep(for: .seconds(2))
        if transfer?.isFinished == true { transfer = nil }
    }

    private func cookies(for domain: DvachDomain) -> [String: String] {
        let jar = HTTPCookieStorage.shared
        let cookies = jar.cookies(for: domain.baseURL) ?? []
        return Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
