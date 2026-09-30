import Foundation

/// Which build of the app this is.
///
/// Two things to know, and they are not the same question:
///
/// - whether the build is *restricted*: boards for adults start hidden, the
///   directory lists the curated boards only, the terms are asked for at first
///   launch and the nude icon is left out. The App Store build is, and so is
///   the sideloaded Release; Debug is not, so the UI tests can reach any board.
/// - whether it is the build meant for the App Store, which is restricted and
///   on top of that cannot post at all.
///
/// The answers come from the app's own `Info.plist`, which XcodeGen fills from
/// a per-configuration build setting. A compilation condition could not do it.
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` set on the app target reaches only the
/// app target, which is one file, and not the packages that hold the
/// preferences; and SwiftPM knows only `debug` and `release`, so a third
/// configuration is invisible to `.define(_:.when(configuration:))` — that
/// would fire for an ordinary Release build too.
///
/// The same route already carries the version number:
/// `CFBundleShortVersionString: $(MARKETING_VERSION)` in `project.yml`, read
/// back out of `Bundle.main` by the About screen.
public enum BuildVariant {
    /// The key XcodeGen writes as `$(NEECHAN_APP_STORE_BUILD)`.
    static let key = "NeechanIsAppStoreBuild"

    /// The key XcodeGen writes as `$(NEECHAN_RESTRICTED_BUILD)`.
    static let restrictedKey = "NeechanIsRestrictedBuild"

    /// Whether this build is the one meant for the App Store.
    ///
    /// Read once. In a test `Bundle.main` is the test runner, which carries no
    /// such key, so this is false — which is what every existing test expects.
    public static let isAppStore = isAppStore(in: Bundle.main.infoDictionary)

    /// Whether this build carries the App Store build's restrictions.
    ///
    /// False in a test, for the same reason ``isAppStore`` is.
    public static let isRestricted = isRestricted(in: Bundle.main.infoDictionary)

    /// Split out from the property so the reading can be tested without
    /// arranging a bundle to read it from.
    static func isAppStore(in info: [String: Any]?) -> Bool {
        flag(key, in: info)
    }

    /// The App Store build counts as restricted whatever the newer key says,
    /// so a plist that lacks it cannot unlock the one build that ships to
    /// strangers.
    static func isRestricted(in info: [String: Any]?) -> Bool {
        isAppStore(in: info) || flag(restrictedKey, in: info)
    }

    /// Reads one of the flags.
    ///
    /// Xcode expands `$(...)` inside a plist as *text*, so the value arrives as
    /// the string `"YES"` or `"NO"` — and as `""` when the build setting is not
    /// defined at all, which is the case worth being sure about: an empty
    /// string must mean the ordinary build, not the App Store one. The boolean
    /// and number cases are here so that a plist edited by hand to `<true/>`
    /// does not quietly read as false.
    private static func flag(_ key: String, in info: [String: Any]?) -> Bool {
        switch info?[key] {
        // Before the number case: a plist `<true/>` bridges to `__NSCFBoolean`,
        // which satisfies both.
        case let flag as Bool: flag
        case let text as String: ["YES", "yes", "true", "TRUE", "1"].contains(text)
        case let number as NSNumber: number.boolValue
        default: false
        }
    }
}
