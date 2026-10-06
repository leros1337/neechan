/// Which of a thread's files the gallery grid shows.
///
/// Split by `GalleryItem.isVideo`, the check the viewer makes to choose a
/// player over an image view, so every file sits under the filter that matches
/// what opens when it is tapped. `Attachment.isVideo` goes by the server's
/// type code alone and calls a `.mov` or an `.mkv` a picture, which the viewer
/// then plays. Everything that is not a video is an image, GIFs included: they
/// are drawn by the image view, and between them the two filters hold the
/// whole thread.
enum GalleryFilter: CaseIterable, Hashable {
    case all
    case videos
    case images

    func includes(_ item: GalleryItem) -> Bool {
        switch self {
        case .all: true
        case .videos: item.isVideo
        case .images: !item.isVideo
        }
    }

    /// The files this filter shows, in the order given.
    func apply(to items: [GalleryItem]) -> [GalleryItem] {
        self == .all ? items : items.filter(includes)
    }
}
