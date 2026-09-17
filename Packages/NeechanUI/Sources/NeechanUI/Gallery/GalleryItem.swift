import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia

/// One thing the gallery can show, with the post it came from.
public struct GalleryItem: Identifiable, Sendable, Hashable {
    public let attachment: NeechanAPI.Attachment
    /// The post the file was attached to, so "go to post" can work.
    public let postNum: Int
    /// The thread the file came from, so a download can be filed under it.
    public let threadKey: ThreadKey

    public var id: String { attachment.path }

    public init(attachment: NeechanAPI.Attachment, postNum: Int, threadKey: ThreadKey) {
        self.attachment = attachment
        self.postNum = postNum
        self.threadKey = threadKey
    }

    /// The files of one post, in the order the post carries them.
    ///
    /// The site comes from the caller: a `Post` carries its board but not the
    /// imageboard it was read from, because the JSON never says.
    public init(attachment: NeechanAPI.Attachment, post: Post, site: Imageboard) {
        self.init(
            attachment: attachment,
            postNum: post.num,
            threadKey: ThreadKey(site: site, board: post.board, threadNum: post.threadNum)
        )
    }

    public var kind: MediaKind {
        MediaKind.resolve(
            fileName: attachment.path,
            declaredTypeCode: attachment.declaredType.rawValue
        )
    }

    public var isVideo: Bool { kind.isVideo }

    /// Size in a form a reader understands.
    public var formattedSize: String {
        ByteCountFormatStyle(style: .file).format(Int64(attachment.sizeBytes))
    }

    /// `1920 × 1080`, or nil when the server did not report a size.
    public var formattedDimensions: String? {
        guard attachment.width > 0, attachment.height > 0 else { return nil }
        return "\(attachment.width) × \(attachment.height)"
    }
}

extension ThreadSnapshot {
    /// Every attachment in the thread, in reading order.
    public var galleryItems: [GalleryItem] {
        posts.flatMap { post in
            post.files.map { GalleryItem(attachment: $0, post: post, site: key.site) }
        }
    }
}

/// What the gallery should open with.
///
/// Used by both the thread and the board list, which each present the gallery
/// as a cover.
struct GalleryStart: Identifiable {
    let items: [GalleryItem]
    let index: Int

    var id: String {
        items.indices.contains(index) ? items[index].id : "\(index)"
    }
}
