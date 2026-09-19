import Foundation
import NeechanSettings
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An icon the app can wear on the home screen.
///
/// The names are the asset catalogue's, which is also what
/// `setAlternateIconName` takes: the one the app ships with has no name at all,
/// which is how the system says "the original".
///
/// The order of the cases is the order of the picker, and `neechan` is last on
/// purpose: it is the one the App Store build leaves out, and the catalogue
/// leaves out the *trailing* `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`
/// entry, so the two stay in step without a hole in the middle of the list.
enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case original
    case peace
    case neechan

    var id: String { rawValue }

    /// What the system calls it, or nil for the icon in the app's own slot.
    var alternateName: String? {
        switch self {
        case .original: nil
        case .peace: "AppIcon2"
        case .neechan: "AppIcon3"
        }
    }

    /// The picture shown beside it in settings.
    ///
    /// A copy that travels with this package rather than the app's catalogue:
    /// an icon in the catalogue belongs to the home screen, and reading one
    /// back out by name is not something the system promises.
    var previewResource: String {
        switch self {
        case .original: "app-icon-default"
        case .peace: "app-icon-peace"
        case .neechan: "app-icon-neechan"
        }
    }

    /// Where that picture lives, so a renamed file is caught by a test rather
    /// than by a blank row in settings.
    var previewURL: URL? {
        Bundle.module.url(forResource: previewResource, withExtension: "png")
    }

    var title: LocalizedStringKey {
        switch self {
        case .original: "Original"
        case .peace: "Peace"
        case .neechan: "Neechan"
        }
    }

    /// The icons this build offers.
    ///
    /// The Neechan artwork is bare-breasted, so the App Store build neither
    /// lists it nor carries it: `project.yml` drops `AppIcon3` from that
    /// configuration's catalogue, and asking for an icon the bundle does not
    /// hold would simply fail. The flag is a parameter so a test can ask for
    /// either build — in a test bundle `Bundle.main` is the runner, which
    /// carries no such key.
    static func available(isAppStoreBuild: Bool = BuildVariant.isAppStore) -> [AppIconChoice] {
        isAppStoreBuild ? allCases.filter { $0 != .neechan } : allCases
    }

    /// Reads a stored name back, falling back to the shipped icon.
    static func named(_ alternateName: String?) -> AppIconChoice {
        allCases.first { $0.alternateName == alternateName } ?? .original
    }
}

/// Puts the chosen icon on the home screen.
enum AppIconSwitcher {
    /// Whether the device will let the icon be changed at all.
    @MainActor
    static var isSupported: Bool {
        #if canImport(UIKit) && os(iOS)
        return UIApplication.shared.supportsAlternateIcons
        #else
        return false
        #endif
    }

    /// The icon the system says is on the home screen right now.
    @MainActor
    static var current: AppIconChoice {
        #if canImport(UIKit) && os(iOS)
        return .named(UIApplication.shared.alternateIconName)
        #else
        return .original
        #endif
    }

    /// - Returns: whether the change took. The system refuses on a device that
    ///   does not allow it, and says nothing useful about why.
    @MainActor
    @discardableResult
    static func apply(_ choice: AppIconChoice) async -> Bool {
        #if canImport(UIKit) && os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else { return false }
        // Asking for the icon already on the home screen puts the system's
        // "you have changed the icon" alert up for nothing.
        guard UIApplication.shared.alternateIconName != choice.alternateName else { return true }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateName)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
}

extension Image {
    /// One of the icon previews that ship with this package.
    init?(iconPreview choice: AppIconChoice) {
        #if canImport(UIKit)
        guard
            let url = choice.previewURL,
            let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        self.init(uiImage: image)
        #else
        return nil
        #endif
    }
}
