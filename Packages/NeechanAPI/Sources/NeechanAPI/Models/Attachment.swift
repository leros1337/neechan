import Foundation

/// A file attached to a post.
///
/// Paths are server-relative; resolve them with `DvachDomain.url(forPath:)` so
/// the app can switch mirrors without rewriting stored data.
public struct Attachment: Sendable, Hashable, Identifiable, Decodable {
    /// Name on the server, for example `17891583643470505794.jpg`.
    public let name: String
    /// The uploader's original file name.
    public let fullName: String
    /// Original name, shortened by the server for display.
    public let displayName: String
    /// Server-relative path to the full file.
    public let path: String
    /// Server-relative path to the thumbnail.
    public let thumbnail: String
    public let md5: String?
    /// The type code the server sent. See `effectiveType` for the corrected one.
    public let declaredType: AttachmentType
    /// File size in kilobytes, as the server reports it.
    public let sizeKB: Int
    public let width: Int
    public let height: Int
    public let thumbnailWidth: Int
    public let thumbnailHeight: Int
    /// Duration of a video, formatted `HH:MM:SS`.
    public let durationText: String?
    public let durationSeconds: Int?
    public let isNSFW: Bool
    /// Sticker pack identifier, for sticker attachments.
    public let stickerPack: String?

    public var id: String { path }

    public var sizeBytes: Int { sizeKB * 1024 }

    /// Lowercased extension taken from the server path.
    public var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    /// The type to actually use.
    ///
    /// 2ch serves WebP under the JPEG and PNG type codes, so the extension wins
    /// when it names a format the code does not.
    public var effectiveType: AttachmentType {
        if fileExtension == "webp" { return .webp }
        return declaredType
    }

    public var isVideo: Bool { effectiveType.isVideo }

    /// True for formats that carry more than one frame.
    public var isAnimated: Bool {
        switch effectiveType {
        case .gif, .apng: true
        default: false
        }
    }

    /// Aspect ratio of the full-size file, or 1 when the server omitted the size.
    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }

    /// Builds an attachment directly, for a site whose JSON is not 2ch's.
    ///
    /// `path` and `thumbnail` may be absolute: `SiteEndpoints.url(forPath:)`
    /// passes an absolute URL through unchanged, which is how a site that
    /// serves its media from another host fits the same model.
    public init(
        name: String = "",
        fullName: String = "",
        displayName: String = "",
        path: String,
        thumbnail: String = "",
        md5: String? = nil,
        declaredType: AttachmentType = .none,
        sizeKB: Int = 0,
        width: Int = 0,
        height: Int = 0,
        thumbnailWidth: Int = 0,
        thumbnailHeight: Int = 0,
        durationText: String? = nil,
        durationSeconds: Int? = nil,
        isNSFW: Bool = false,
        stickerPack: String? = nil
    ) {
        self.name = name
        self.fullName = fullName
        self.displayName = displayName.isEmpty ? fullName : displayName
        self.path = path
        self.thumbnail = thumbnail
        self.md5 = md5
        self.declaredType = declaredType
        self.sizeKB = sizeKB
        self.width = width
        self.height = height
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.durationText = durationText
        self.durationSeconds = durationSeconds
        self.isNSFW = isNSFW
        self.stickerPack = stickerPack
    }

    private enum CodingKeys: String, CodingKey {
        case name, fullname, displayname, path, thumbnail, md5, type, size
        case width, height
        case tnWidth = "tn_width"
        case tnHeight = "tn_height"
        case duration
        case durationSecs = "duration_secs"
        case nsfw, pack
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        fullName = try c.decodeIfPresent(String.self, forKey: .fullname) ?? name
        displayName = try c.decodeIfPresent(String.self, forKey: .displayname) ?? fullName
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail) ?? path
        md5 = try c.decodeIfPresent(String.self, forKey: .md5)
        declaredType = AttachmentType(rawValue: try c.decodeIfPresent(Int.self, forKey: .type) ?? 0)
        sizeKB = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        thumbnailWidth = try c.decodeIfPresent(Int.self, forKey: .tnWidth) ?? 0
        thumbnailHeight = try c.decodeIfPresent(Int.self, forKey: .tnHeight) ?? 0
        durationText = try c.decodeIfPresent(String.self, forKey: .duration)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSecs)
        // The spec says "NSFW when >= 0", which would make 0 mean NSFW; the live
        // data only ever sends a positive value for flagged files.
        isNSFW = (try c.decodeIfPresent(Int.self, forKey: .nsfw) ?? 0) > 0
        stickerPack = try c.decodeIfPresent(String.self, forKey: .pack)
    }
}

/// The file type codes 2ch uses.
public enum AttachmentType: Sendable, Hashable {
    case none
    case jpeg
    case png
    case apng
    case gif
    case bmp
    case webm
    case mp3
    case ogg
    case mp4
    case sticker
    /// Served under a JPEG or PNG code; recognised from the file extension.
    case webp
    /// A code this client does not know, kept so it can be reported.
    case unknown(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .none
        case 1: .jpeg
        case 2: .png
        case 3: .apng
        case 4: .gif
        case 5: .bmp
        case 6: .webm
        case 7: .mp3
        case 8: .ogg
        case 10: .mp4
        case 100: .sticker
        default: .unknown(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .none: 0
        case .jpeg: 1
        case .png: 2
        case .apng: 3
        case .gif: 4
        case .bmp: 5
        case .webm: 6
        case .mp3: 7
        case .ogg: 8
        case .mp4: 10
        case .sticker: 100
        // WebP has no code of its own; report the code it arrives under.
        case .webp: 1
        case .unknown(let value): value
        }
    }

    /// The type named by a file extension.
    ///
    /// For a site that reports the extension rather than a numeric code. The
    /// leading dot is optional, because 4chan's `ext` carries one.
    public init(fileExtension: String) {
        let ext = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        self = switch ext {
        case "jpg", "jpeg": .jpeg
        case "png": .png
        case "gif": .gif
        case "bmp": .bmp
        case "webp": .webp
        case "webm": .webm
        case "mp4", "m4v": .mp4
        case "mp3": .mp3
        case "ogg": .ogg
        // No code of its own on either site; kept recognisable rather than
        // silently reported as "no file".
        default: .unknown(-1)
        }
    }

    public var isVideo: Bool {
        switch self {
        case .webm, .mp4: true
        default: false
        }
    }

    public var isAudio: Bool {
        switch self {
        case .mp3, .ogg: true
        default: false
        }
    }
}
