#if canImport(Photos)
import Foundation
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

    /// Saves the file at `url`. Videos and images take different asset types,
    /// so the kind is passed rather than guessed from the extension twice.
    public static func save(fileAt url: URL, isVideo: Bool) async throws {
        guard await requestAuthorization() else { throw SaveError.notAuthorised }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: nil)
            }
        } catch {
            throw SaveError.failed(String(describing: error))
        }
    }
}
#endif
