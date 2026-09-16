import Foundation
import SwiftData

/// The first persisted schema.
///
/// Versioned from the very first release so that a later change has somewhere
/// to migrate from; SwiftData cannot retrofit a version onto an unversioned
/// store without losing it.
public enum NeechanSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            HistoryEntry.self,
            WatchedThreadState.self,
            Draft.self,
            DraftAttachment.self,
            OwnPost.self,
            Favorite.self,
            FavoriteBoard.self,
            HiddenThread.self,
            HiddenPostRule.self,
            AutohideRule.self,
            SavedThread.self,
            StoredTheme.self,
        ]
    }
}

/// The migration path between schema versions. Empty while there is only one.
///
/// A property that is added with a default — `readPostsCount` was — needs no
/// stage: SwiftData migrates the store itself. Writing one anyway crashed the
/// app on launch, because a stage compares two `VersionedSchema`s and both of
/// ours name the same live model types: a version is only meaningful once the
/// old shape is frozen in its own copy of the models, which is worth doing when
/// a change is not lightweight, and not before.
public enum NeechanMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [NeechanSchemaV1.self]
    }

    public static var stages: [MigrationStage] { [] }
}
