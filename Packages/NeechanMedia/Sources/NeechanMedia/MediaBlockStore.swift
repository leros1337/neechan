import CryptoKit
import Foundation

/// Pieces of remote files, kept so that what has been fetched once is not
/// fetched again.
///
/// A streamed video used to leave nothing behind: reopening a clip fetched it
/// again, and so did seeking back over ground already watched. Playback reads a
/// file in pieces rather than whole, so what is kept is pieces.
///
/// Fixed, aligned blocks, one file each. A block is present exactly when its
/// file exists, so there is no index to persist, nothing to keep in step with
/// the files, and nothing to repair after the app is killed mid-write.
///
/// A lock-guarded class rather than an actor on purpose. `MediaRangeReader`
/// drives this from the decoder's demuxing thread and blocks while it reads, so
/// it cannot await; an actor would be unreachable from the one caller that
/// matters most. `MediaCache` is an actor and calls in synchronously, which is
/// allowed and costs nothing.
public final class MediaBlockStore: @unchecked Sendable {
    public static let shared = MediaBlockStore()

    /// How much of a file one block holds.
    ///
    /// A megabyte is roughly a second of a board video: small enough that
    /// sampling a clip does not pull much, large enough that a long one is not
    /// thousands of files.
    public static let defaultBlockSize = 1 << 20

    public let blockSize: Int

    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(directory: URL? = nil, blockSize: Int = MediaBlockStore.defaultBlockSize) {
        self.directory = directory ?? URL.cachesDirectory.appending(path: "NeechanMediaBlocks")
        self.blockSize = max(1, blockSize)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: Reading and writing

    /// The bytes of one block, if that block has been fetched.
    public func block(_ index: Int, for url: URL) -> Data? {
        lock.withLock {
            try? Data(contentsOf: blockLocation(index, for: url))
        }
    }

    /// Keeps one block.
    ///
    /// Written atomically, so a process that dies part way through leaves the
    /// old block or none at all, never half of one.
    public func store(_ data: Data, block index: Int, for url: URL) {
        lock.withLock {
            let folder = folderLocation(for: url)
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: blockLocation(index, for: url), options: .atomic)
        }
    }

    /// The file's total size, as the server reported it.
    public func length(for url: URL) -> Int64? {
        lock.withLock {
            guard
                let text = try? String(contentsOf: lengthLocation(for: url), encoding: .utf8)
            else { return nil }
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func setLength(_ length: Int64, for url: URL) {
        lock.withLock {
            let folder = folderLocation(for: url)
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("\(length)".utf8).write(to: lengthLocation(for: url), options: .atomic)
        }
    }

    // MARK: What is held

    /// How many blocks a file of this size is made of.
    public func blockCount(forTotal total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int((total + Int64(blockSize) - 1) / Int64(blockSize))
    }

    /// The blocks of this file that have not been fetched yet.
    public func missingBlocks(for url: URL, total: Int64) -> [Int] {
        let count = blockCount(forTotal: total)
        guard count > 0 else { return [] }
        return lock.withLock {
            (0..<count).filter { index in
                !fileManager.fileExists(atPath: blockLocation(index, for: url).path)
            }
        }
    }

    public func isComplete(for url: URL, total: Int64) -> Bool {
        missingBlocks(for: url, total: total).isEmpty
    }

    // MARK: Turning pieces back into a file

    public enum StoreError: Error {
        /// Asked to assemble a file that is not all here.
        case incomplete
    }

    /// Joins the blocks into one file and returns where it landed.
    ///
    /// The caller owns the result; nothing here points at it afterwards. Used
    /// when something wants the whole clip rather than the part being watched:
    /// saving it, sharing it, or keeping it for offline reading.
    public func assemble(for url: URL) throws -> URL {
        guard let total = length(for: url), isComplete(for: url, total: total) else {
            throw StoreError.incomplete
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw StoreError.incomplete
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for index in 0..<blockCount(forTotal: total) {
            guard let piece = block(index, for: url) else { throw StoreError.incomplete }
            try handle.write(contentsOf: piece)
        }
        return destination
    }

    // MARK: Housekeeping

    /// One file's worth of blocks, as eviction sees it.
    ///
    /// A whole file is one entry rather than one per block, so a long clip is
    /// not thrown away a megabyte at a time.
    public struct Entry: Sendable {
        public let url: URL
        public let size: Int
        public let accessedAt: Date
    }

    public func entries() -> [Entry] {
        lock.withLock {
            guard
                let folders = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { return [] }

            return folders.compactMap { folder in
                guard
                    let files = try? fileManager.contentsOfDirectory(
                        at: folder,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ), !files.isEmpty
                else { return nil }

                var size = 0
                var newest = Date.distantPast
                for file in files {
                    let values = try? file.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey]
                    )
                    size += values?.fileSize ?? 0
                    if let date = values?.contentModificationDate, date > newest { newest = date }
                }
                return Entry(url: folder, size: size, accessedAt: newest)
            }
        }
    }

    public func sizeOnDisk() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Drops everything held for one file.
    public func remove(_ url: URL) {
        lock.withLock {
            try? fileManager.removeItem(at: folderLocation(for: url))
        }
    }

    /// Drops one entry by its directory, for eviction, which works from
    /// `entries` rather than from URLs it can no longer recover.
    public func remove(entry: Entry) {
        lock.withLock {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    public func removeAll() {
        lock.withLock {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Locations

    /// Hashed, so the name is short and legal whatever the URL looked like, and
    /// stable, so the same file always lands in the same place. The same scheme
    /// `MediaCache` uses for whole files.
    private func folderLocation(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined())
    }

    private func blockLocation(_ index: Int, for url: URL) -> URL {
        folderLocation(for: url).appending(path: "\(index).blk")
    }

    private func lengthLocation(for url: URL) -> URL {
        folderLocation(for: url).appending(path: "length")
    }
}
