import Foundation

/// Which page the gallery fetches ahead of the reader.
///
/// The next page only, and only when it is a picture: a clip is warmed by
/// `GalleryViewModel.warmNextVideo`, which fetches its head rather than all of
/// it. A picture is fetched whole and decoded, so the swipe onto it shows the
/// picture rather than a spinner.
enum GalleryPreloadPolicy {
    /// 10 MB. A larger file is fetched only once the reader lands on it: on a
    /// metered connection it is real money for a page they may never turn to,
    /// and decoded it is the largest thing the gallery holds.
    static let byteLimit = 10 * 1024 * 1024

    /// What was decided about the page after this one, and why.
    enum Decision: Equatable {
        case preload(GalleryItem)
        /// The last page has nothing after it.
        case nothingNext
        case video
        /// The server did not say how large the file is.
        case sizeUnknown
        case tooLarge(bytes: Int)
    }

    static func decision(after index: Int, in items: [GalleryItem]) -> Decision {
        let next = index + 1
        guard index >= 0, items.indices.contains(next) else { return .nothingNext }
        let item = items[next]
        if item.isVideo { return .video }
        let bytes = item.attachment.sizeBytes
        if bytes <= 0 { return .sizeUnknown }
        if bytes > byteLimit { return .tooLarge(bytes: bytes) }
        return .preload(item)
    }

    /// The page after `index`, when it is a picture worth fetching ahead.
    static func pictureToPreload(after index: Int, in items: [GalleryItem]) -> GalleryItem? {
        if case .preload(let item) = decision(after: index, in: items) { return item }
        return nil
    }
}
