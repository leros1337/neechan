import CryptoKit
import Foundation

/// A size-capped disk cache for whole media files.
///
/// `URLCache` refuses to store responses beyond a fraction of its capacity, so
/// a 20 MB WebM is never cached by it and every reopen re-downloads. This keeps
/// the bytes itself and evicts least-recently-used files once over budget.
public actor MediaCache {
    public static let shared = MediaCache(blocks: .shared)

    private let directory: URL
    private var byteLimit: Int
    /// Days a file may go unused before it is dropped, or zero to keep it.
    private var maxAgeDays: Int = 0
    private let fileManager = FileManager.default

    /// Pieces of files still being watched, when this cache is answering for
    /// them too.
    ///
    /// Held so that one number in settings covers everything the app is keeping:
    /// the size shown, the budget applied and the Clear button all reach both
    /// stores through here, and cannot drift apart.
    private let blocks: MediaBlockStore?

    public init(
        directory: URL? = nil,
        byteLimit: Int = 512 * 1024 * 1024,
        blocks: MediaBlockStore? = nil
    ) {
        self.directory = directory ?? URL.cachesDirectory.appending(path: "NeechanMedia")
        self.byteLimit = byteLimit
        self.blocks = blocks
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Changes the budget, evicting immediately if the cache is now over it.
    public func setByteLimit(_ bytes: Int) {
        byteLimit = max(1, bytes)
        evictIfNeeded()
    }

    /// The budget in force, for the settings screen to show.
    public func currentByteLimit() -> Int { byteLimit }

    /// Sets how long something may go unused before it is dropped.
    ///
    /// - Parameter days: zero keeps everything, and is what this did before the
    ///   reader was given the choice.
    public func setMaxAge(days: Int) {
        maxAgeDays = max(0, days)
        evictIfNeeded()
    }

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
        blocks?.removeAll()
    }

    /// Bytes currently held.
    public func currentSize() -> Int {
        contents().reduce(0) { $0 + $1.size } + (blocks?.sizeOnDisk() ?? 0)
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

    /// Drops the oldest files until the cache is inside its budget.
    ///
    /// Public so the app can ask on the way to the background, which is the one
    /// moment there is time to spare and the one moment the reader will not
    /// notice. Until now eviction only ever ran while storing something, so a
    /// cache that was over budget stayed over it until the next download.
    public func evictIfNeeded() {
        evictExpired()
        evictBlocks()

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

    /// Drops whatever has gone untouched for longer than the reader allows.
    ///
    /// Runs before the size check, so a cache inside its budget still lets go
    /// of what nobody has looked at, which is the whole point of asking how
    /// long to keep things.
    private func evictExpired() {
        guard maxAgeDays > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(maxAgeDays) * 24 * 60 * 60)

        for entry in contents() where entry.accessedAt < cutoff {
            try? fileManager.removeItem(at: entry.url)
        }
        if let blocks {
            for entry in blocks.entries() where entry.accessedAt < cutoff {
                blocks.remove(entry: entry)
            }
        }
    }

    /// Keeps the half-finished files to a corner of the budget.
    ///
    /// A quarter, and never less than 32 MB. They are worth keeping, since they
    /// are what a reader is part way through, but a handful of long clips nobody
    /// finished must not crowd out the files that are whole.
    private func evictBlocks() {
        guard let blocks else { return }
        let limit = max(32 * 1024 * 1024, byteLimit / 4)

        var entries = blocks.entries()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }

        // A whole file's pieces go together: dropping one piece of a clip only
        // leaves a hole that has to be fetched again later.
        entries.sort { $0.accessedAt < $1.accessedAt }
        for entry in entries {
            guard total > limit else { break }
            blocks.remove(entry: entry)
            total -= entry.size
        }
    }

    /// Records a read so eviction can tell hot files from cold ones.
    ///
    /// Both dates are written, because eviction sorts on the access date where
    /// the file system reports one and falls back to the modification date where
    /// it does not; setting only one of them left hot files looking cold.
    private func touch(_ file: URL) {
        let now = Date.now
        try? fileManager.setAttributes(
            [.modificationDate: now], ofItemAtPath: file.path
        )
        var values = URLResourceValues()
        values.contentAccessDate = now
        var url = file
        try? url.setResourceValues(values)
    }
}
