import CryptoKit
import Foundation

/// A size-capped disk cache for whole media files.
///
/// `URLCache` refuses to store responses beyond a fraction of its capacity, so
/// a 20 MB WebM is never cached by it and every reopen re-downloads. This keeps
/// the bytes itself and evicts least-recently-used files once over budget.
public actor MediaCache {
    public static let shared = MediaCache()

    private let directory: URL
    private var byteLimit: Int
    private let fileManager = FileManager.default

    public init(
        directory: URL? = nil,
        byteLimit: Int = 512 * 1024 * 1024
    ) {
        self.directory = directory ?? URL.cachesDirectory.appending(path: "NeechanMedia")
        self.byteLimit = byteLimit
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Changes the budget, evicting immediately if the cache is now over it.
    public func setByteLimit(_ bytes: Int) {
        byteLimit = max(1, bytes)
        evictIfNeeded()
    }

    /// The budget in force, for the settings screen to show.
    public func currentByteLimit() -> Int { byteLimit }

    /// Where a URL's bytes live, if they have been stored.
    public func cachedFile(for url: URL) -> URL? {
        let file = location(for: url)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        touch(file)
        return file
    }

    /// Stores `data` for `url` and returns where it landed.
    @discardableResult
    public func store(_ data: Data, for url: URL) throws -> URL {
        let file = location(for: url)
        try data.write(to: file, options: .atomic)
        evictIfNeeded()
        return file
    }

    /// Moves an already-downloaded file into the cache.
    @discardableResult
    public func adopt(fileAt source: URL, for url: URL) throws -> URL {
        let destination = location(for: url)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        evictIfNeeded()
        return destination
    }

    public func remove(_ url: URL) {
        try? fileManager.removeItem(at: location(for: url))
    }

    public func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Bytes currently held.
    public func currentSize() -> Int {
        contents().reduce(0) { $0 + $1.size }
    }

    // MARK: Internals

    /// A hash keeps the file name short and legal whatever the URL looked like,
    /// while staying stable so the same URL always maps to the same file.
    private func location(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let fileExtension = url.pathExtension
        return directory.appending(
            path: fileExtension.isEmpty ? name : "\(name).\(fileExtension)"
        )
    }

    private struct Entry {
        let url: URL
        let size: Int
        let accessedAt: Date
    }

    private func contents() -> [Entry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return Entry(
                url: file,
                size: values.fileSize ?? 0,
                accessedAt: values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            )
        }
    }

    private func evictIfNeeded() {
        var entries = contents()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }

        // Oldest access first, so what the reader is scrolling through survives.
        entries.sort { $0.accessedAt < $1.accessedAt }
        for entry in entries {
            guard total > byteLimit else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Records a read so eviction can tell hot files from cold ones.
    private func touch(_ file: URL) {
        try? fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
    }
}
