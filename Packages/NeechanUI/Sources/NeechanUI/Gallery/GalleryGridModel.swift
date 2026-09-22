import Foundation
import NeechanCore
import Observation

/// Saving and sharing from the thread's gallery grid.
///
/// The viewer acts on the file on screen; the grid has every file on screen at
/// once, so each action here names the one that was pressed.
@MainActor
@Observable
final class GalleryGridModel {
    let transfers: MediaTransferController
    private let services: AppServices

    init(services: AppServices, transfers: MediaTransferController? = nil) {
        self.services = services
        self.transfers = transfers ?? MediaTransferController(services: services)
    }

    func url(for item: GalleryItem) -> URL? {
        item.endpoints(mirror: services.settings.domain).url(forPath: item.attachment.path)
    }

    /// Saves the file, to Photos or to the folder the reader picked.
    func save(_ item: GalleryItem) {
        guard let url = url(for: item) else { return }
        transfers.save(item, at: url)
    }

    /// Downloads the file and returns it for the share sheet.
    func fileForSharing(_ item: GalleryItem) async -> URL? {
        guard let url = url(for: item) else { return nil }
        return await transfers.fileForSharing(item, at: url)
    }
}
