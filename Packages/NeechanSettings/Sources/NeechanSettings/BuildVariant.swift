import Foundation

/// Which build of the app this is.
///
/// There is one thing to know: whether this is the build meant for the App
/// Store, which starts cautious and does not allow posting at all.
///
/// The answer comes from the app's own `Info.plist`, which XcodeGen fills from
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

    /// Whether this build is the one meant for the App Store.
    ///
    /// Read once. In a test `Bundle.main` is the test runner, which carries no
    /// such key, so this is false — which is what every existing test expects.
    public static let isAppStore = isAppStore(in: Bundle.main.infoDictionary)

    /// Split out from the property so the reading can be tested without
    /// arranging a bundle to read it from.
    ///
    /// Xcode expands `$(...)` inside a plist as *text*, so the value arrives as
    /// the string `"YES"` or `"NO"` — and as `""` when the build setting is not
    /// defined at all, which is the case worth being sure about: an empty
    /// string must mean the ordinary build, not the App Store one. The boolean
    /// and number cases are here so that a plist edited by hand to `<true/>`
    /// does not quietly read as false.
    static func isAppStore(in info: [String: Any]?) -> Bool {
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
