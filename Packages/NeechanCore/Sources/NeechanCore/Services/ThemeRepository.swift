import Foundation
import SwiftData

/// Holds the themes the reader has imported.
@ModelActor
public actor ThemeRepository {
    /// Every theme: the shipped schemes first, then whatever was imported.
    public func themes() throws -> [NeechanTheme] {
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredTheme>(sortBy: [SortDescriptor(\.name)])
        )
        return NeechanTheme.builtIns + stored.compactMap(Self.decode)
    }

    /// Reads a theme file and keeps it. Importing the same theme again replaces
    /// the copy already held rather than adding a second one.
    @discardableResult
    public func `import`(_ data: Data) throws -> NeechanTheme {
        let theme = try ThemeJSONDecoder.decode(data)
        let payload = try JSONEncoder().encode(theme)

        if let existing = try stored(id: theme.id) {
            existing.name = theme.name
            existing.payload = payload
        } else {
            modelContext.insert(
                StoredTheme(themeID: theme.id, name: theme.name, payload: payload)
            )
        }
        try modelContext.save()
        return theme
    }

    /// The theme with this id, or the built-in one when it is missing. A theme
    /// can be deleted while it is still the one selected in settings.
    public func theme(id: String?) throws -> NeechanTheme {
        guard let id else { return .builtIn }
        if let shipped = NeechanTheme.builtIn(id: id) { return shipped }
        return try stored(id: id).flatMap(Self.decode) ?? .builtIn
    }

    /// Removes an imported theme. The built-in one stays.
    public func remove(id: String) throws {
        guard NeechanTheme.builtIn(id: id) == nil, let existing = try stored(id: id) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func stored(id: String) throws -> StoredTheme? {
        var descriptor = FetchDescriptor<StoredTheme>(
            predicate: #Predicate { $0.themeID == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func decode(_ stored: StoredTheme) -> NeechanTheme? {
        try? JSONDecoder().decode(NeechanTheme.self, from: stored.payload)
    }
}
