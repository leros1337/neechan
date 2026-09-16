import Foundation
import Synchronization

/// The language the app draws itself in.
///
/// SwiftUI resolves `Text("…", bundle: .module)` against the `\.locale` in the
/// environment, which is how the language picker works. Strings built in code
/// with `String(localized:)` do not see that environment: left alone they
/// follow the *device's* language, so on an English phone set to Russian in the
/// app, every error message stayed English.
///
/// Held here, in the lowest layer, because all four packages build strings that
/// way and this is the only module every one of them can see.
public enum AppLocale {
    private static let storage = Mutex<Locale>(.autoupdatingCurrent)

    /// Pass this to every `String(localized:)`.
    public static var current: Locale {
        storage.withLock { $0 }
    }

    /// Follows the reader's choice; nil means follow the device.
    public static func set(_ locale: Locale?) {
        storage.withLock { $0 = locale ?? .autoupdatingCurrent }
    }
}
