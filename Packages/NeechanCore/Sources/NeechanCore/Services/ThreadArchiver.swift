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
    @discardableResult
    public func save(
        _ response: ThreadResponse,
        rawJSON: Data,
        key: ThreadKey,
        domain: DvachDomain,
        policy: MediaPolicy,
        downloader: any MediaFetching,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SavedThreadItem {
        let relative = "\(key.board)-\(key.threadNum)"
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
                guard let url = domain.url(forPath: path) else { continue }
                if let data = try? await downloader.data(url, referer: domain.baseURL) {
                    let destination = media.appending(path: Self.fileName(for: path))
                    try? data.write(to: destination, options: .atomic)
                }
            }
            downloaded += 1
            onProgress?(Double(downloaded) / Double(max(attachments.count, 1)))
        }

        let stored = try storedThread(key) ?? {
            let new = SavedThread(
                board: key.board,
                threadNum: key.threadNum,
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
    public func load(_ key: ThreadKey) throws -> ThreadResponse? {
        guard let stored = try storedThread(key) else { return nil }
        let url = Self.rootDirectory
            .appending(path: stored.directoryRelativePath)
            .appending(path: "thread.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(ThreadResponse.self, from: data)
    }

    /// Where a saved thread's media folder is, for resolving its attachments.
    public func mediaDirectory(for key: ThreadKey) throws -> String? {
        try storedThread(key)?.directoryRelativePath
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

    public func saved() throws -> [SavedThreadItem] {
        try modelContext.fetch(
            FetchDescriptor<SavedThread>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        )
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

    public func removeAll() throws {
        try? FileManager.default.removeItem(at: Self.rootDirectory)
        try modelContext.delete(model: SavedThread.self)
        try modelContext.save()
    }

    /// Total bytes held by every saved thread.
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
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<SavedThread>(
            predicate: #Predicate { $0.board == board && $0.threadNum == threadNum }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension SavedThreadItem {
    init(_ stored: SavedThread) {
        self.init(
            key: ThreadKey(board: stored.board, threadNum: stored.threadNum),
            title: stored.title,
            savedAt: stored.savedAt,
            postsCount: stored.postsCount,
            filesCount: stored.filesCount,
            bytesOnDisk: stored.bytesOnDisk,
            includesFiles: stored.includesFiles
        )
    }
}
