import Foundation
import NeechanAPI
import SwiftData

/// The migration path between schema versions.
///
/// V1 knew one imageboard. Every row it wrote was 2ch's, which is what the new
/// `siteRaw` default says, so the inferred migration does the backfill itself;
/// the stage exists to prove it did rather than to do it.
///
/// A property added with a default needs no stage — `readPostsCount` was — and
/// writing one anyway crashed the app on launch the first time, because a stage
/// compares two `VersionedSchema`s and both named the same live model types: a
/// version is only meaningful once the old shape is frozen in its own copy of
/// the models. That is now done, in `NeechanSchemaV1`, because this change is
/// *not* lightweight: `#Unique` moves from `(board, threadNum)` onto
/// `(site, board, threadNum)`, which changes the entity and is not something to
/// leave to inference.
public enum NeechanMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [NeechanSchemaV1.self, NeechanSchemaV2.self]
    }

    static let v1ToV2 = MigrationStage.custom(
        fromVersion: NeechanSchemaV1.self,
        toVersion: NeechanSchemaV2.self,
        // Nothing to do: the new constraint is strictly weaker than the old, so
        // no row that satisfied `(board, threadNum)` can collide under
        // `(site, board, threadNum)`.
        willMigrate: nil,
        didMigrate: { context in
            // Belt and braces. A non-optional attribute with a default is
            // honoured by the inferred migration, but a row that came back
            // empty would be a row no site-scoped query could ever find again,
            // and the reader would see it as their favourites having vanished.
            let dvach = Imageboard.dvach.rawValue
            for favorite in try context.fetch(FetchDescriptor<NeechanSchemaV2.Favorite>())
            where favorite.siteRaw.isEmpty {
                favorite.siteRaw = dvach
            }
            for board in try context.fetch(FetchDescriptor<NeechanSchemaV2.FavoriteBoard>())
            where board.siteRaw.isEmpty {
                board.siteRaw = dvach
            }
            for entry in try context.fetch(FetchDescriptor<NeechanSchemaV2.HistoryEntry>())
            where entry.siteRaw.isEmpty {
                entry.siteRaw = dvach
            }
            for state in try context.fetch(FetchDescriptor<NeechanSchemaV2.WatchedThreadState>())
            where state.siteRaw.isEmpty {
                state.siteRaw = dvach
            }
            for draft in try context.fetch(FetchDescriptor<NeechanSchemaV2.Draft>())
            where draft.siteRaw.isEmpty {
                draft.siteRaw = dvach
            }
            for post in try context.fetch(FetchDescriptor<NeechanSchemaV2.OwnPost>())
            where post.siteRaw.isEmpty {
                post.siteRaw = dvach
            }
            for thread in try context.fetch(FetchDescriptor<NeechanSchemaV2.HiddenThread>())
            where thread.siteRaw.isEmpty {
                thread.siteRaw = dvach
            }
            for rule in try context.fetch(FetchDescriptor<NeechanSchemaV2.HiddenPostRule>())
            where rule.siteRaw.isEmpty {
                rule.siteRaw = dvach
            }
            for thread in try context.fetch(FetchDescriptor<NeechanSchemaV2.SavedThread>())
            where thread.siteRaw.isEmpty {
                thread.siteRaw = dvach
            }
            // `AutohideRule` is deliberately absent: its empty `sitesRaw` means
            // every imageboard, so a rule carried over keeps working on both.
            try context.save()
        }
    )

    public static var stages: [MigrationStage] { [v1ToV2] }
}
