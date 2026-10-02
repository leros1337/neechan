import Foundation
import NeechanSettings

extension AppServices {
    /// Everything worth carrying to another device, as one backup.
    ///
    /// The settings and statistics live in `AppSettings` rather than the store,
    /// so they are read here and handed to the export. Leaving them out is
    /// what made every backup restore the favourites and reset everything else.
    public func makeBackup() async throws -> NeechanBackup {
        try await backup.export(
            preferences: settings.backupPreferences(),
            statistics: settings.statistics
        )
    }

    /// What a restore did.
    public struct RestoreSummary: Sendable, Equatable {
        public var imported: BackupService.ImportSummary
        /// False for a file from before the settings were carried.
        public var restoredSettings: Bool
    }

    /// Brings a backup in: what is missing from the store is added, the
    /// statistics are merged, and the backup's settings are taken.
    ///
    /// The store first, because the themes have to be there before the setting
    /// that picks one says so. Then the imageboard, the one safe way: `select`
    /// re-points the client before the setting is seen, where writing it with
    /// the rest let the board list reload against the site being left.
    ///
    /// The app icon is the caller's to put on the home screen: only the system
    /// can, and this layer does not reach it.
    public func restore(from document: NeechanBackup) async throws -> RestoreSummary {
        let imported = try await backup.import(document)
        if let statistics = document.usageStatistics {
            settings.mergeStatistics(statistics)
        }
        guard let preferences = document.preferencesBackup else {
            return RestoreSummary(imported: imported, restoredSettings: false)
        }
        select(settings.imageboard(after: preferences))
        settings.applyBackupPreferences(preferences)
        return RestoreSummary(imported: imported, restoredSettings: true)
    }
}
