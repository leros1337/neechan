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

    /// - Parameter inMemory: used by tests, so each one starts clean and
    ///   nothing touches the user's real database.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Neechan",
            schema: Schema(NeechanSchemaV1.models),
            isStoredInMemoryOnly: inMemory
        )
        do {
            return try ModelContainer(
                for: Schema(NeechanSchemaV1.models),
                migrationPlan: NeechanMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw StoreError.containerUnavailable(underlying: error)
        }
    }
}
