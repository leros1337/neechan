import Foundation

extension MediaKind {
    /// Works out how to present a file from its name and, when the server gave
    /// one, its type code.
    ///
    /// The extension is trusted over the code because 2ch serves WebP under the
    /// JPEG and PNG codes.
    public static func resolve(fileName: String, declaredTypeCode: Int? = nil) -> MediaKind {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "webm", "mkv":
            return .webmVideo
        case "mp4", "m4v", "mov":
            return .mp4Video
        case "gif":
            return .animatedImage
        case "apng":
            return .animatedImage
        case "png", "jpg", "jpeg", "bmp", "webp":
            // A still by extension; an animated PNG or WebP is only detectable
            // by inspecting the file, which `AnimatedImageDecoder` does when it
            // actually loads the bytes.
            return .stillImage
        default:
            break
        }

        switch declaredTypeCode {
        case 6: return .webmVideo
        case 10: return .mp4Video
        case 3, 4: return .animatedImage
        case 1, 2, 5: return .stillImage
        default: return .stillImage
        }
    }
}
