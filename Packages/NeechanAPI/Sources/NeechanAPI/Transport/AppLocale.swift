import Foundation
import Synchronization

/// The language the app draws itself in.
///
/// SwiftUI resolves `Text("…", bundle: .module)` against the `\.locale` in the
/// environment, which is how the language picker works. Strings built in code
/// with `String(localized:)` do not see that environment: left alone they
/// follow the *device's* language, so on a phone set to Russian with the app
/// set to English, every error message stayed Russian.
///
/// Passing this as the `locale:` is not enough on its own. That argument only
/// formats what is interpolated; the translation is chosen by the bundle,
/// which is why every such string also asks for `.forAppLanguage()` of its
/// bundle. Believing the locale was enough left every string built in code in
/// the device's language for as long as this has existed.
///
/// Held here, in the lowest layer, because all four packages build strings that
/// way and this is the only module every one of them can see.
public enum AppLocale {
    /// The reader's choice, or nil when the app follows the device.
    private static let storage = Mutex<Locale?>(nil)

    /// Pass this as the `locale:` of every `String(localized:)`.
    public static var current: Locale {
        storage.withLock { $0 } ?? .autoupdatingCurrent
    }

    /// The language the reader picked in the app, or nil when it follows the
    /// device's.
    public static var chosen: Locale? {
        storage.withLock { $0 }
    }

    /// Follows the reader's choice; nil means follow the device.
    public static func set(_ locale: Locale?) {
        storage.withLock { $0 = locale }
    }
}

extension Bundle {
    /// This bundle's table for the language the reader picked in the app.
    ///
    /// Pass it as the `bundle:` of every `String(localized:)`, beside
    /// `locale: AppLocale.current`. When the app follows the device this is the
    /// bundle itself, which already looks up the device's language.
    public func forAppLanguage() -> Bundle {
        localized(for: AppLocale.chosen)
    }

    /// The `.lproj` inside this bundle for `locale`, or the bundle itself when
    /// there is no locale or no table for it.
    ///
    /// Tried from the most particular spelling to the least, so `ru_RU` finds
    /// `ru.lproj` and a script such as `zh-Hans` is not reduced to `zh` while a
    /// table for it exists.
    func localized(for locale: Locale?) -> Bundle {
        guard let locale else { return self }
        let candidates: [String?] = [
            locale.identifier,
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            locale.language.minimalIdentifier,
            locale.language.languageCode?.identifier,
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let path = path(forResource: candidate, ofType: "lproj"), let table = Bundle(path: path) {
                return table
            }
        }
        return self
    }
}
