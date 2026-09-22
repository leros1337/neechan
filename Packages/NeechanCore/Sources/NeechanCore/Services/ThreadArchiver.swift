import Foundation
import NeechanAPI
import SwiftData

/// A thread saved for offline reading, as a value.
public struct SavedThreadItem: Sendable, Hashable, Identifiable {
    public let key: ThreadKey
    public let title: String
    public let savedAt: Date
    public let postsCount: Int
    public let filesCount: Int
    public let bytesOnDisk: Int
    public let includesFiles: Bool

    public var id: ThreadKey { key }
}

/// Saves threads to the device and reads them back without a network.
@ModelActor
public actor SavedThreadsRepository {

    /// What the reader is willing to be shown. Read per query, so turning a
    /// restriction on takes effect without rebuilding this actor.
    private nonisolated let policyPort = ContentPolicyPort()

    /// - Parameter policy: read on every listing, never stored as a value.
    public init(modelContainer: ModelContainer, policy: @escaping ContentPolicyProvider) {
        self.init(modelContainer: modelContainer)
        policyPort.use(policy)
    }
    public enum SaveError: Error {
        case cannotWrite(String)
    }

    /// Everything saved lives under one folder, so clearing it is one delete.
    public static let rootDirectoryName = "SavedThreads"

    /// What to keep alongside the text.
    public enum MediaPolicy: Sendable {
        /// Thumbnails only: small, and enough to recognise a post.
        case thumbnails
        /// Full files too, which can be hundreds of megabytes.
        case fullFiles
    }

    /// Writes a thread to disk.
    ///
    /// The JSON snapshot is written first, so a save interrupted midway through
    /// downloading media still leaves a readable thread.
    ///
    /// - Parameter onProgress: called with the number of attachments stored so
    ///   far and the number there are in total. Attachments, not requests: a
    ///   full save fetches a thumbnail *and* the file for each one, and a count
    ///   that moved twice per picture would not be the count a reader is
    ///   watching. Called from this actor, so a main-actor observer has to hop.
    @discardableResult
    public func save(
        _ response: ThreadResponse,
        rawJSON: Data,
        key: ThreadKey,
        endpoints: SiteEndpoints,
        policy: MediaPolicy,
        downloader: any MediaFetching,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> SavedThreadItem {
        // Qualified by the site so two imageboards' /b/12345 do not share a
        // folder. Folders written before this are found by the path stored on
        // their own row, so nothing on disk has to move.
        let relative = key.identifier
        let directory = Self.rootDirectory.appending(path: relative)
        let media = directory.appending(path: "media")

        do {
            try FileManager.default.createDirectory(
                at: media, withIntermediateDirectories: true
            )
            // The server's own bytes, so the saved copy is exactly what was
            // served rather than a re-encoding of the app's models.
            try rawJSON.write(
                to: directory.appending(path: "thread.json"), options: .atomic
            )
        } catch {
            throw SaveError.cannotWrite(String(describing: error))
        }

        let attachments = response.posts.flatMap(\.files)
        var downloaded = 0
        for attachment in attachments {
            guard !Task.isCancelled else { break }
            let paths = policy == .fullFiles
                ? [attachment.thumbnail, attachment.path]
                : [attachment.thumbnail]

            for path in paths {
                guard let url = endpoints.url(forPath: path) else { continue }
                if let data = try? await downloader.data(url, referer: endpoints.web) {
                    let destination = media.appending(path: Self.fileName(for: path))
                    try? data.write(to: destination, options: .atomic)
                }
            }
            downloaded += 1
            onProgress?(downloaded, attachments.count)
        }

        let stored = try storedThread(key) ?? {
            let new = SavedThread(
                key: key,
                title: response.title,
                directoryRelativePath: relative
            )
            modelContext.insert(new)
            return new
        }()
        stored.title = response.title
        stored.savedAt = .now
        stored.postsCount = response.posts.count
        stored.filesCount = attachments.count
        stored.includesFiles = policy == .fullFiles
        stored.bytesOnDisk = Self.directorySize(directory)
        try modelContext.save()

        return SavedThreadItem(stored)
    }

    /// Reads a saved thread back, without touching the network.
    ///
    /// Decoded the way the site that wrote it writes threads, which the row has
    /// recorded since the schema gained `siteRaw`. Reading them all as 2ch's
    /// shape is what kept saving off on 4chan: the bytes were fine and nothing
    /// could read them.
    ///
    /// The board is a placeholder. 4chan's mapping refuses without one and
    /// there is none on disk -- and none to be fetched either, since the whole
    /// point of a saved thread is that it opens with no network. What a
    /// placeholder costs is the board's posting limits and flags, which nothing
    /// on a saved thread reads. 2ch does not even look: its own board object is
    /// inside the bytes.
    ///
    /// The mirror in the selection is the default one, and that is fine: 2ch's
    /// decode ignores endpoints, and its attachment paths stay server-relative
    /// and are resolved against whichever mirror the reader is on when a
    /// thumbnail is drawn.
    public func load(_ key: ThreadKey) throws -> ThreadResponse? {
        guard let stored = try storedThread(key) else { return nil }
        let url = Self.rootDirectory
            .appending(path: stored.directoryRelativePath)
            .appending(path: "thread.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let response = try StoredThread.response(
            from: data,
            on: SiteSelection(site: stored.site),
            board: Board(id: key.board, defaultName: "Anonymous")
        )
        return Self.pointingAtLocalMedia(response, in: stored.directoryRelativePath)
    }

    /// Repoints a thread's attachments at the copies kept beside it.
    ///
    /// The files were being downloaded and never read: a saved thread still
    /// asked the site for every thumbnail, so "offline" meant the text and
    /// nothing else. Rewriting the paths here rather than teaching each screen
    /// about saved copies is what keeps the thumbnails, the gallery and the
    /// player as they are -- `SiteEndpoints.url(forPath:)` hands back an
    /// absolute URL untouched, and a `file:` URL is absolute.
    ///
    /// A path with no file beside it is left pointing at the site. That is the
    /// thumbnails-only save, whose full files were never fetched: the thumbnail
    /// comes off the disk and the full picture is asked for if the reader opens
    /// it and there is a network to ask over.
    nonisolated static func pointingAtLocalMedia(
        _ response: ThreadResponse,
        in directory: String
    ) -> ThreadResponse {
        var response = response
        response.posts = response.posts.map { post in
            var post = post
            post.files = post.files.map { file in
                var file = file
                if let local = localMediaURL(for: file.path, in: directory) {
                    file.path = local.absoluteString
                }
                if let local = localMediaURL(for: file.thumbnail, in: directory) {
                    file.thumbnail = local.absoluteString
                }
                return file
            }
            return post
        }
        return response
    }

    /// Where a saved attachment lives, if it was kept.
    public nonisolated static func localMediaURL(
        for path: String,
        in relativeDirectory: String
    ) -> URL? {
        let url = rootDirectory
            .appending(path: relativeDirectory)
            .appending(path: "media")
            .appending(path: fileName(for: path))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func saved(site: Imageboard) throws -> [SavedThreadItem] {
        let siteRaw = site.rawValue
        return try modelContext.fetch(
            FetchDescriptor<SavedThread>(
                predicate: #Predicate { $0.siteRaw == siteRaw },
                sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
            )
        )
        .filter { policyPort.policy.allows(code: $0.board, on: site) }
        .map(SavedThreadItem.init)
    }

    public func isSaved(_ key: ThreadKey) throws -> Bool {
        try storedThread(key) != nil
    }

    public func remove(_ key: ThreadKey) throws {
        guard let stored = try storedThread(key) else { return }
        try? FileManager.default.removeItem(
            at: Self.rootDirectory.appending(path: stored.directoryRelativePath)
        )
        modelContext.delete(stored)
        try modelContext.save()
    }

    /// Deletes every thread saved from one imageboard.
    ///
    /// Row by row rather than by emptying the root folder: the screen that
    /// offers this shows one site, and wiping the directory would take the
    /// other site's threads with it.
    public func removeAll(site: Imageboard) throws {
        let siteRaw = site.rawValue
        let stored = try modelContext.fetch(
            FetchDescriptor<SavedThread>(predicate: #Predicate { $0.siteRaw == siteRaw })
        )
        for thread in stored {
            try? FileManager.default.removeItem(
                at: Self.rootDirectory.appending(path: thread.directoryRelativePath)
            )
            modelContext.delete(thread)
        }
        try modelContext.save()
    }

    /// Total bytes held by every saved thread, on every imageboard.
    ///
    /// Site-blind on purpose: this backs the storage row in the media settings,
    /// and disk usage is disk usage whichever site filled it.
    public func totalBytesOnDisk() throws -> Int {
        try modelContext.fetch(FetchDescriptor<SavedThread>())
            .reduce(0) { $0 + $1.bytesOnDisk }
    }

    // MARK: Internals

    nonisolated static var rootDirectory: URL {
        URL.applicationSupportDirectory.appending(path: rootDirectoryName)
    }

    /// A flat name for a server path, so one folder holds every file without
    /// recreating the site's directory tree.
    nonisolated static func fileName(for path: String) -> String {
        path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "_")
    }

    nonisolated static func directorySize(_ url: URL) -> Int {
        guard
            let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey]
            )
        else {
            return 0
        }
        var total = 0
        for case let file as URL in files {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private func storedThread(_ key: ThreadKey) throws -> SavedThread? {
        let site = key.site.rawValue
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<SavedThread>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension SavedThreadItem {
    init(_ stored: SavedThread) {
        self.init(
            key: stored.key,
            title: stored.title,
            savedAt: stored.savedAt,
            postsCount: stored.postsCount,
            filesCount: stored.filesCount,
            bytesOnDisk: stored.bytesOnDisk,
            includesFiles: stored.includesFiles
        )
    }
}
