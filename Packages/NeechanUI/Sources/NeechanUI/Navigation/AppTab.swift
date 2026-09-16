import SwiftUI

/// The top-level sections of the app.
///
/// Search is deliberately not a case here: it is a `Tab(role: .search)`, which
/// iOS 26 renders as its own floating capsule beside the minimized tab bar.
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case boards
    case favorites
    case history
    case settings

    public var id: String { rawValue }

    /// The section's name, for the tab bar and the iPad sidebar.
    public var title: Text {
        switch self {
        case .boards: Text("Boards", bundle: .module)
        case .favorites: Text("Favorites", bundle: .module)
        case .history: Text("History", bundle: .module)
        case .settings: Text("Settings", bundle: .module)
        }
    }

    /// SF Symbol shown in the tab bar.
    public var systemImage: String {
        switch self {
        case .boards: "square.grid.2x2"
        case .favorites: "star"
        case .history: "clock"
        case .settings: "gearshape"
        }
    }
}
