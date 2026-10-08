import Foundation
import NeechanAPI

/// An image search engine that looks a picture up by its address.
///
/// Every one of these fetches the picture itself, from the address it is
/// handed, so nothing is uploaded from the device and nothing the app holds,
/// such as a passcode's cookie, goes with it.
enum ReverseImageSearch: CaseIterable, Identifiable {
    case yandex
    case googleLens
    case sauceNAO
    case iqdb

    var id: Self { self }

    /// The engine's own name, which is the same in every language.
    var title: String {
        switch self {
        case .yandex: "Yandex"
        case .googleLens: "Google Lens"
        case .sauceNAO: "SauceNAO"
        case .iqdb: "iqdb"
        }
    }

    /// The engine's results page for the picture at `image`.
    func url(for image: URL) -> URL {
        // Encoded as one query value: the picture's own slashes, colon and
        // query would otherwise be read as the engine's.
        let value = image.absoluteString.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        return URL(string: prefix + value)!
    }

    private var prefix: String {
        switch self {
        case .yandex: "https://yandex.com/images/search?rpt=imageview&url="
        case .googleLens: "https://lens.google.com/uploadbyurl?url="
        case .sauceNAO: "https://saucenao.com/search.php?url="
        case .iqdb: "https://iqdb.org/?url="
        }
    }

    /// RFC 3986's unreserved characters, the only ones safe inside a value.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

extension GalleryItem {
    /// The picture an image search engine is handed for this file, or nil when
    /// no engine could fetch one.
    ///
    /// A picture is searched by the file itself. A video by the still the site
    /// made of it, since no engine takes a clip. A thread saved for offline
    /// reading keeps its files on the device, where no engine can reach them.
    func searchableImageURL(mirror: DvachDomain) -> URL? {
        let path = isVideo ? attachment.thumbnail : attachment.path
        guard let url = endpoints(mirror: mirror).url(forPath: path), !url.isFileURL else { return nil }
        return url
    }
}
