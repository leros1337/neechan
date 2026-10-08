import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia

/// A link in a post that leads straight to a picture or a clip.
///
/// Read so the viewer can open it the way it opens a file attached to a post.
/// It used to go to the browser like any page, so a tap on a `.mp4` brought
/// up a Safari sheet for a clip the app could have played itself.
struct MediaLink: Hashable {
    /// The file, as the viewer opens it.
    let attachment: NeechanAPI.Attachment
    /// The board the file is filed under, when an imageboard's own host serves
    /// it. Nil for a file anywhere else, and for one outside any board.
    let board: BoardRef?

    /// What the viewer shows, by extension. The address is all a link has to
    /// go on: nothing is fetched to find out what is behind it.
    private static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv",
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
    ]

    /// - Parameter site: the imageboard of the thread the link is in. A link
    ///   with no host is a path on it, and a link to any of its hosts is read
    ///   through the mirror the app is set to.
    init?(url: URL, readingOn site: Imageboard) {
        let host = url.host()?.lowercased()
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard host != nil else { return nil }
        case nil:
            guard host == nil, url.path().hasPrefix("/") else { return nil }
        default:
            return nil
        }
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { return nil }

        let owner: Imageboard?
        let isSiteHost: Bool
        if let host {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if let linked = Imageboard.allCases.first(where: { $0.linkHosts.contains(bare) }) {
                owner = linked
                isSiteHost = true
            } else {
                // A site whose files live on a host of their own: 4chan's are
                // on i.4cdn.org, which no reader writes a thread link to.
                owner = Imageboard.allCases.first {
                    SiteEndpoints(SiteSelection(site: $0)).media.host() == bare
                }
                isSiteHost = false
            }
        } else {
            owner = site
            isSiteHost = true
        }

        // The host is dropped for a file on the site being read, so it is
        // fetched from the mirror the app is set to, with the referer and the
        // cookies that mirror expects. The mirror a link names is often one
        // that has since gone dark. Anywhere else the address stays whole: the
        // selected mirror means nothing to another site's file.
        let path = owner == site && isSiteHost ? url.path() : url.absoluteString

        let name = url.lastPathComponent
        attachment = NeechanAPI.Attachment(
            name: name,
            fullName: name,
            path: path,
            declaredType: Self.type(of: name)
        )
        board = owner.flatMap { owner in
            url.pathComponents.dropFirst().first
                .flatMap { BoardCode.normalized($0, for: owner) }
                .map { BoardRef(site: owner, code: $0) }
        }
    }

    /// Whether the reader's restrictions let the viewer show it.
    ///
    /// A file on a board is judged as the board would be. A file anywhere else
    /// follows the rule the in-app browser does: a link a stranger wrote is
    /// shown on a surface this app answers for only once the reader has said
    /// they are 18. Refused, the link goes out the way it always did.
    func isAllowed(by policy: ContentPolicy) -> Bool {
        guard let board else { return policy.allowsMatureBoards }
        return policy.allowsOpening(board)
    }

    /// The type code to file it under.
    ///
    /// Stored because the viewer reads the kind from the stored path first and
    /// the code second. A signed link carries its query after the extension,
    /// which hides the extension from that read, and the code is what is left.
    private static func type(of name: String) -> AttachmentType {
        switch MediaKind.resolve(fileName: name) {
        case .mp4Video: .mp4
        case .webmVideo: .webm
        case .animatedImage: .gif
        case .stillImage: AttachmentType(fileExtension: (name as NSString).pathExtension)
        }
    }
}
