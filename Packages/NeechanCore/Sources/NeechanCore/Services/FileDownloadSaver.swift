import Foundation
import NeechanSettings

/// Writes a downloaded file into a folder the reader chose.
///
/// The folder comes from the document picker and is reached through a
/// security-scoped bookmark, which has to be resolved and opened before
/// anything can be written inside it.
public enum FileDownloadSaver {
    public enum SaveError: Error, Equatable {
        /// The folder the reader picked is gone, or access to it was withdrawn.
        case destinationUnavailable
        /// The name was taken and the reader's choice was to skip.
        case skipped
    }

    /// Moves `source` into `folder`, under `subpath`, as `name`.
    ///
    /// - Returns: where the file landed.
    @discardableResult
    public static func save(
        fileAt source: URL,
        named name: String,
        in folder: URL,
        subpath: [String],
        conflict: DownloadConflictAction
    ) throws -> URL {
        let directory = subpath.reduce(folder) { $0.appending(path: $1) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        )
        guard
            let chosen = ConflictResolver.resolve(
                fileName: name, existing: existing, action: conflict
            )
        else {
            throw SaveError.skipped
        }

        let destination = directory.appending(path: chosen)
        // Replacing is the only case where something is already there, and
        // `moveItem` refuses to overwrite.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// The same, through the bookmark stored in settings.
    @discardableResult
    public static func save(
        fileAt source: URL,
        named name: String,
        bookmark: Data,
        subpath: [String],
        conflict: DownloadConflictAction
    ) throws -> URL {
        var isStale = false
        guard
            let folder = try? URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkResolutionOptions,
                bookmarkDataIsStale: &isStale
            )
        else {
            throw SaveError.destinationUnavailable
        }

        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }

        return try save(
            fileAt: source, named: name, in: folder, subpath: subpath, conflict: conflict
        )
    }

    /// Makes a bookmark that survives relaunching, for a folder the reader just
    /// picked.
    public static func bookmark(for folder: URL) throws -> Data {
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }
        return try folder.bookmarkData(options: bookmarkCreationOptions)
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        [.minimalBookmark]
        #endif
    }
}
