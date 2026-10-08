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

    // MARK: Picking files to save

    /// Set while the reader is picking files to save, when a tap ticks a file
    /// rather than opening it.
    var isSelecting = false {
        didSet { if !isSelecting { selection.removeAll() } }
    }
    private var selection: Set<GalleryItem.ID> = []

    func isSelected(_ item: GalleryItem) -> Bool {
        selection.contains(item.id)
    }

    func toggleSelection(_ item: GalleryItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    /// How many of `items` are ticked.
    ///
    /// Counted against what the grid shows rather than everything ever
    /// ticked: a file the filter has put out of sight is not saved, so it is
    /// not counted either.
    func selectionCount(in items: [GalleryItem]) -> Int {
        items.count { selection.contains($0.id) }
    }

    /// Ticks every file shown, or clears them when they already all are.
    func toggleSelectAll(in shown: [GalleryItem]) {
        let ids = Set(shown.map(\.id))
        if ids.isSubset(of: selection) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    /// Saves the ticked files among `shown`, in the order the grid shows them,
    /// and stops picking.
    func saveSelection(in shown: [GalleryItem]) {
        let picked = shown.filter { selection.contains($0.id) }
        isSelecting = false
        transfers.save(picked.compactMap { item in url(for: item).map { (item, $0) } })
    }
}
