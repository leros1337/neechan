import Foundation

/// The hosts one imageboard serves its parts from.
///
/// 2ch serves everything from one host; 4chan splits the JSON API, the media,
/// the static assets, the readable site and the posting endpoint across five.
/// Resolving a stored path therefore has to know which of them it belongs to.
public struct SiteEndpoints: Sendable, Hashable {
    /// Where the JSON comes from.
    public let api: URL
    /// Where attachments and thumbnails come from.
    public let media: URL
    /// Where flags, spoiler images and other site furniture come from.
    public let assets: URL
    /// The readable site, for links the reader shares or opens in a browser.
    public let web: URL
    /// Where a post is sent.
    public let posting: URL

    public init(api: URL, media: URL, assets: URL, web: URL, posting: URL) {
        self.api = api
        self.media = media
        self.assets = assets
        self.web = web
        self.posting = posting
    }

    public init(_ selection: SiteSelection) {
        switch selection.site {
        case .dvach:
            let base = selection.mirror.baseURL
            self.init(api: base, media: base, assets: base, web: base, posting: base)
        case .fourchan:
            self.init(
                api: URL(string: "https://a.4cdn.org")!,
                media: URL(string: "https://i.4cdn.org")!,
                assets: URL(string: "https://s.4cdn.org")!,
                web: URL(string: "https://boards.4chan.org")!,
                posting: URL(string: "https://sys.4chan.org")!
            )
        }
    }

    /// Resolves a server-relative path (`/b/src/123/456.jpg`) against the media
    /// host.
    ///
    /// Absolute URLs are returned unchanged. That is what lets a site whose
    /// media lives on another host store absolute paths in the very same model
    /// field, with nothing downstream needing to know.
    public func url(forPath path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        return URL(string: path, relativeTo: media)?.absoluteURL
    }
}
