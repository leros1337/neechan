import Foundation
import SwiftData

/// Builds the app's SwiftData container.
public enum NeechanStore {
    public enum StoreError: Error, CustomStringConvertible {
        case containerUnavailable(underlying: any Error)

        public var description: String {
            switch self {
            case .containerUnavailable(let underlying):
                "Could not open the Neechan store: \(underlying)"
            }
        }
    }

    /// The shapes the app runs against right now.
    ///
    /// Everything that needs a schema asks for this rather than naming a
    /// version, so the fallback container in the app's own launch path cannot
    /// drift a version behind the store it is standing in for.
    public static var currentModels: [any PersistentModel.Type] { NeechanSchemaV2.models }

    /// - Parameter inMemory: used by tests, so each one starts clean and
    ///   nothing touches the user's real database.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Neechan",
            schema: Schema(currentModels),
            isStoredInMemoryOnly: inMemory
        )
        return try makeContainer(configuration: configuration)
    }

    /// Opens a store at a path of the caller's choosing.
    ///
    /// For the migration tests: an in-memory store starts empty, so it cannot
    /// exercise reading an older one.
    public static func makeContainer(at url: URL) throws -> ModelContainer {
        try makeContainer(configuration: ModelConfiguration("Neechan", schema: Schema(currentModels), url: url))
    }

    private static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(
                for: Schema(currentModels),
                migrationPlan: NeechanMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw StoreError.containerUnavailable(underlying: error)
        }
    }
}
