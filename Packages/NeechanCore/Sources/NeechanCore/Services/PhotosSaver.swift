#if canImport(Photos)
import Foundation
import os
import Photos

/// Saves images and videos to the reader's photo library.
public enum PhotosSaver {
    public enum SaveError: Error, CustomStringConvertible {
        case notAuthorised
        case failed(String)

        public var description: String {
            switch self {
            case .notAuthorised: "Neechan is not allowed to add to your photo library."
            case .failed(let reason): reason
            }
        }
    }

    /// Asks for add-only access, which is all saving needs and the least the
    /// reader has to grant.
    public static func requestAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static let log = Logger(subsystem: "io.neechan.media", category: "photos")

    /// Saves the file at `url`. Videos and images take different asset types,
    /// so the kind is passed rather than guessed from the extension twice.
    public static func save(fileAt url: URL, isVideo: Bool) async throws {
        guard await requestAuthorization() else { throw SaveError.notAuthorised }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        log.debug(
            """
            saving \(url.lastPathComponent, privacy: .public),             \(size ?? 0, privacy: .public) bytes, video: \(isVideo, privacy: .public)
            """
        )

        let placeholder = OSAllocatedUnfairLock<String?>(initialState: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // Saved now, so it turns up at the top of the library rather
                // than filed under whatever date the file happened to carry.
                // A clip downloaded from a board often carries one from years
                // ago, and an asset that lands there looks like it was never
                // saved at all.
                request.creationDate = Date()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
                placeholder.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
            }
        } catch {
            log.error("Photos refused it: \(String(describing: error), privacy: .public)")
            throw SaveError.failed(String(describing: error))
        }

        let identifier = placeholder.withLock { $0 }
        log.debug("Photos took it as \(identifier ?? "an asset with no identifier", privacy: .public)")

        // Deliberately not fetched back to check it survived. Reading the
        // library needs full access, and this app asks only to add, which is
        // the least it can ask for and all saving needs. Asking for the asset
        // back crashes outright for want of the permission to look, so what
        // Photos says when the change is committed has to be taken at its
        // word.
    }
}
#endif
