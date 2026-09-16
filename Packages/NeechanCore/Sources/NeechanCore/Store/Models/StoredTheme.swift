import Foundation
import SwiftData

/// An imported theme, kept as the decoded value so a later change to the
/// Dashchan format cannot break themes already installed.
@Model
public final class StoredTheme {
    #Unique<StoredTheme>([\.themeID])

    public var themeID: String = ""
    public var name: String = ""
    public var createdAt: Date = Date.now
    /// The encoded `NeechanTheme`.
    public var payload: Data = Data()

    public init(themeID: String, name: String, payload: Data, createdAt: Date = .now) {
        self.themeID = themeID
        self.name = name
        self.payload = payload
        self.createdAt = createdAt
    }
}
