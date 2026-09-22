import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia
import Observation
import SwiftUI

/// Saving and sharing one attachment, with the capsule that reports on it.
///
/// Lifted out of `GalleryViewModel` when a second screen needed the same thing.
/// It is the whole awkward middle of a save — download what is not already on
/// disk, re-encode a WebM that Photos would refuse, write it where the reader
/// asked, and say so — and none of that is about a gallery.
///
/// Takes the item and its URL per call rather than reading a current index, so
/// a caller with no index of its own can use it.
@MainActor
@Observable
public final class MediaTransferController {
    /// What a save or a share is doing, or nil when nothing is in flight.
    ///
    /// Shown as a capsule over the media rather than as an alert at the end: a
    /// 20 MB clip on a slow connection used to look like a button that did
    /// nothing until it was suddenly finished.
    public private(set) var transfer: Transfer?
    public var saveResult: SaveResult?
    /// The outcome of the last video save, for the view to answer with a tap.
    public private(set) var lastVideoSave: VideoSaveOutcome?

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


    /// How the most recent video save ended.
    ///
    /// Carries an id so that two saves which ended the same way are two separate
    /// events rather than one value that never changes, which is what a feedback
    /// trigger needs in order to fire twice. The same shape as the thread view's
    /// refresh announcement, for the same reason.
    public struct VideoSaveOutcome: Equatable, Sendable {
        public let id = UUID()
        public let succeeded: Bool

        public init(succeeded: Bool) {
            self.succeeded = succeeded
        }
    }



    private let services: AppServices
    private let downloader: any MediaDownloading
    /// Where whole files and half-watched pieces are kept. Injectable so a test
    /// works in a directory of its own rather than in the reader's real cache.
    private let cache: MediaCache
    private let blocks: MediaBlockStore
    /// The work behind `transfer`, kept so Cancel has something to stop.
    private var transferTask: Task<Void, Never>?
    /// When the last progress update was published.
    ///
    /// The downloader reports every 64 KB, which is some hundreds of times for
    /// a clip; redrawing that often costs more than the download does.
    private var lastProgressPublished = ContinuousClock.now

    public init(
        services: AppServices,
        downloader: (any MediaDownloading)? = nil,
        cache: MediaCache = .shared,
        blocks: MediaBlockStore = .shared
    ) {
        self.services = services
        self.downloader = downloader ?? services.downloader
        self.cache = cache
        self.blocks = blocks
    }

    /// What the media host expects to see as the page the file was linked from.
    ///
    /// Per item rather than per session: a pasted link can carry the reader to
    /// the other imageboard, and a 2ch referer on a 4chan file is wrong even
    /// where it is accepted.
    private func referer(for item: GalleryItem) -> URL? {
        item.endpoints(mirror: services.settings.domain).web
    }

    /// Saves the current file, to Photos or to the folder the reader picked.
    ///
    /// Photos is the default because it needs no setup; a chosen folder is used
    /// as soon as there is one, and keeps the board and thread structure.
    public func save(_ item: GalleryItem, at url: URL) {
        guard transferTask == nil else { return }
        transferTask = Task { [weak self] in
            await self?.performSave(item, at: url)
            self?.transferTask = nil
        }
    }

    /// Stops whatever is in flight and clears the capsule.
    public func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        transfer = nil
    }

    private func performSave(_ item: GalleryItem, at url: URL) async {
        let settings = services.settings
        transfer = Transfer(stage: .downloading, fraction: 0)

        // Everything written to the temporary directory on the way to a save.
        // A cancelled save used to leave both the download and a half-written
        // conversion behind, and nothing ever came back for them.
        var scratch: [URL] = []
        defer {
            for file in scratch { try? FileManager.default.removeItem(at: file) }
        }

        do {
            let downloaded = try await wholeFile(url, referer: referer(for: item))
            scratch.append(downloaded)
            guard !Task.isCancelled else { return }
            let file = try await converted(downloaded, of: item)
            if file != downloaded { scratch.append(file) }
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
                try await saveToPhotos(file, of: item, isOriginal: file == downloaded)
            }
            finish()
            noteVideoSave(item, succeeded: true)
        } catch FileDownloadSaver.SaveError.skipped {
            // Skipping is what the reader asked for, not a failure. The capsule
            // says the transfer finished, so the tap agrees with the screen.
            finish()
            noteVideoSave(item, succeeded: true)
        } catch is CancellationError {
            // No tap for either of these: the reader stopped it and knows.
            transfer = nil
        } catch Downloader.DownloadError.cancelled {
            transfer = nil
        } catch {
            transfer = nil
            saveResult = .failed(error.readableSaveMessage)
            noteVideoSave(item, succeeded: false)
        }
    }

    /// Notes how a save ended, for the view to answer with a haptic.
    ///
    /// Images are left out on purpose. They save in a moment, so a tap would say
    /// nothing the screen had not already said, and the reader's thumb is still
    /// on the button when it happens.
    private func noteVideoSave(_ item: GalleryItem, succeeded: Bool) {
        guard item.isVideo else { return }
        lastVideoSave = VideoSaveOutcome(succeeded: succeeded)
    }

    /// Downloads the current file and returns it for the share sheet.
    public func fileForSharing(_ item: GalleryItem, at url: URL) async -> URL? {
        transfer = Transfer(stage: .downloading, fraction: 0)
        defer { transfer = nil }
        return try? await wholeFile(url, referer: referer(for: item))
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

    /// Saves to the photo library, converting the file first if the library
    /// will not have it as it stands.
    ///
    /// Photos reads a narrower set of files than this app plays. WebM it
    /// refuses outright, which is why that is converted before it is ever
    /// offered. MP4 it usually takes, but not always: the boards serve HEVC
    /// tagged `hev1`, and Photos cannot read that any more than AVFoundation
    /// can play it. Converting every MP4 on the chance would cost every reader
    /// a re-encode they almost never need, so the file is offered as it is and
    /// converted only if that is refused.
    private func saveToPhotos(_ file: URL, of item: GalleryItem, isOriginal: Bool) async throws {
        do {
            try await PhotosSaver.save(fileAt: file, isVideo: item.isVideo)
            return
        } catch let error as PhotosSaver.SaveError {
            guard case .failed = error, item.isVideo, isOriginal else { throw error }
        }

        transfer = Transfer(stage: .converting, fraction: 0)
        let destination = file.deletingPathExtension()
            .appendingPathExtension("converted")
            .appendingPathExtension("mp4")
        // Cleans up after itself: the caller tracks what it downloaded, not
        // what this made along the way.
        defer { try? FileManager.default.removeItem(at: destination) }

        try await WebMConverter().convert(fileAt: file, to: destination) { [weak self] fraction in
            Task { @MainActor in self?.publishConversion(fraction) }
        }

        transfer = Transfer(stage: .saving, fraction: nil)
        try await PhotosSaver.save(fileAt: destination, isVideo: item.isVideo)
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

    /// A copy of the whole file, for saving or sharing.
    ///
    /// Goes through the cache rather than straight to the network: a clip just
    /// watched is already on disk, in whole or in pieces, and downloading it
    /// again was costing the reader the file twice. A copy, because both callers
    /// delete what they are given.
    private func wholeFile(_ url: URL, referer: URL?) async throws -> URL {
        try await LocalMediaFile.exportCopy(
            url, referer: referer, downloader: downloader, cache: cache, blocks: blocks
        ) { [weak self] progress in
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

}
