import Foundation
import NeechanCore
import NeechanMedia
import Observation
import os

/// What the gallery writes to the log: which page landed, what it was shown
/// from, and what was fetched ahead of it.
///
/// `log stream --predicate 'subsystem == "io.neechan.media" AND category == "gallery"'`
enum GalleryLog {
    static let log = Logger(subsystem: "io.neechan.media", category: "gallery")
}

/// The gallery's decoded pictures, held by the viewer rather than by its pages.
///
/// A page used to hold its own picture, and threw it away every time it became
/// the page on screen: a spinner, the file read off the disk again, decoded
/// again at full size, and a new zoom view built for it, at the end of every
/// swipe, even back to a picture just seen. A paged view is no owner for it
/// either, since it builds two copies of the page it lands on.
///
/// Here a picture is decoded once and handed to every copy of its page as the
/// same image, and a load asked for twice, by the page and by the preload, is
/// one fetch and one decode. Only a window of pages around the one on screen
/// is kept, because a full-size picture decoded is tens of megabytes.
@MainActor
@Observable
final class GalleryImageStore {
    enum Entry {
        case loading
        case loaded(GalleryMediaLoader.Loaded)
        case failed(Failure)
    }

    enum Failure: Equatable, Sendable {
        case notAnImage
        case other(String)
    }

    private(set) var entries: [GalleryItem.ID: Entry] = [:]

    @ObservationIgnored private var inFlight: [GalleryItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let fetcher: any MediaFetching
    @ObservationIgnored private let cache: MediaCache

    init(fetcher: any MediaFetching, cache: MediaCache = .shared) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// Whether the picture is decoded and ready to draw.
    func isLoaded(_ id: GalleryItem.ID) -> Bool {
        if case .loaded = entries[id] { return true }
        return false
    }

    /// Loads a picture, returning once it is decoded or has failed.
    ///
    /// Free for a picture already held, and joins one already on its way. A
    /// picture that failed is tried again: landing on it is the retry.
    func load(_ id: GalleryItem.ID, url: URL, referer: URL) async {
        await start(id, url: url, referer: referer, priority: nil)?.value
    }

    /// Starts loading a picture the reader has not reached yet.
    ///
    /// At a lower priority than the page on screen, which can join it and so
    /// raise it when the reader gets there first.
    func preload(_ id: GalleryItem.ID, url: URL, referer: URL) {
        start(id, url: url, referer: referer, priority: .utility)
    }

    /// Lets go of every picture but these, and stops fetching the rest.
    func keep(only ids: Set<GalleryItem.ID>) {
        for (id, task) in inFlight where !ids.contains(id) {
            task.cancel()
            inFlight[id] = nil
            GalleryLog.log.debug("cancelled \(id, privacy: .public)")
        }
        let dropped = entries.keys.filter { !ids.contains($0) }
        guard !dropped.isEmpty else { return }
        for id in dropped {
            GalleryLog.log.debug("dropped \(id, privacy: .public)")
        }
        entries = entries.filter { ids.contains($0.key) }
    }

    @discardableResult
    private func start(
        _ id: GalleryItem.ID, url: URL, referer: URL, priority: TaskPriority?
    ) -> Task<Void, Never>? {
        if case .loaded = entries[id] { return nil }
        if let running = inFlight[id] { return running }

        entries[id] = .loading
        let task = Task(priority: priority) { [weak self, fetcher, cache] in
            let started = ContinuousClock.now
            let outcome: Result<(loaded: GalleryMediaLoader.Loaded, fromDisk: Bool), any Error>
            do {
                outcome = .success(try await GalleryMediaLoader.load(
                    url: url, referer: referer, fetcher: fetcher, cache: cache
                ))
            } catch {
                outcome = .failure(error)
            }
            // Let go of while it was on its way: `keep(only:)` has already
            // forgotten it, and a load started since owns the entry now.
            guard !Task.isCancelled, let self else { return }
            self.finish(id, outcome, after: ContinuousClock.now - started)
        }
        inFlight[id] = task
        return task
    }

    private func finish(
        _ id: GalleryItem.ID,
        _ outcome: Result<(loaded: GalleryMediaLoader.Loaded, fromDisk: Bool), any Error>,
        after elapsed: Duration
    ) {
        inFlight[id] = nil
        let ms = Int(elapsed / .milliseconds(1))
        switch outcome {
        case .success(let result):
            entries[id] = .loaded(result.loaded)
            let source = result.fromDisk ? "disk" : "network"
            GalleryLog.log.debug(
                "loaded \(id, privacy: .public) (\(source, privacy: .public)) in \(ms) ms, \(Self.describe(result.loaded), privacy: .public)"
            )
        case .failure(let error as GalleryMediaLoader.LoadError):
            entries[id] = .failed(.notAnImage)
            GalleryLog.log.error("failed \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        case .failure(let error):
            entries[id] = .failed(.other(String(describing: error)))
            GalleryLog.log.error("failed \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static func describe(_ loaded: GalleryMediaLoader.Loaded) -> String {
        switch loaded {
        case .still(let image):
            #if canImport(UIKit)
            let scale = image.scale
            #else
            let scale: CGFloat = 1
            #endif
            return "\(Int(image.size.width * scale))×\(Int(image.size.height * scale))"
        case .animated:
            return "animation"
        }
    }
}
