import Foundation
import Testing
@testable import NeechanSettings

@MainActor
@Suite("App settings")
struct AppSettingsTests {
    /// Each test gets its own defaults so one test's writes cannot reach another.
    private func makeSettings() throws -> AppSettings {
        let name = "neechan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return AppSettings(defaults: defaults)
    }

    @Test("a fresh install starts on sensible defaults")
    func defaults() throws {
        let settings = try makeSettings()

        #expect(settings.mediaLoadPolicy == .always)
        #expect(settings.appearance == .system)
        #expect(settings.textScale == 1)
        #expect(settings.thumbnailScale == 0.8, "thumbnails start a little under full size")
        #expect(settings.remembersHistory)
        #expect(settings.locksApp == false, "the app does not lock itself until asked")
        #expect(settings.catalogByDefault, "a board opens as the catalog until told otherwise")
        #expect(settings.convertsWebMOnSave, "Photos cannot play a WebM, so it is converted by default")
        #expect(settings.showsHiddenThreads, "hiding a thread collapses it rather than removing it")
        #expect(settings.usesInternalBrowser)
        #expect(settings.videoLoops == false)
        #expect(settings.downloadConflictAction == .keepBoth)
        #expect(settings.collapsePostLineLimit == 12)
        #expect(settings.autoRefreshIntervalSeconds == 0, "auto refresh is off until asked for")
        #expect(settings.downloadSubdirectoryPattern == "<board>/<thread>")
    }

    /// Everything a file carries about where it came from goes by default: the
    /// site refuses a file it has seen before, photos carry location data, and
    /// a camera roll name says which device took it.
    @Test("uploads are cleaned up by default")
    func uploadDefaults() throws {
        let settings = try makeSettings()

        #expect(settings.appendsUniqueHashByDefault)
        #expect(settings.stripsMetadataByDefault)
        #expect(settings.removesFileNamesByDefault)
    }

    @Test("each of the upload defaults can be turned off")
    func uploadDefaultsCanBeDisabled() throws {
        let settings = try makeSettings()

        settings.appendsUniqueHashByDefault = false
        settings.stripsMetadataByDefault = false
        settings.removesFileNamesByDefault = false

        #expect(settings.appendsUniqueHashByDefault == false)
        #expect(settings.stripsMetadataByDefault == false)
        #expect(settings.removesFileNamesByDefault == false)
    }

    @Test("scales stay inside a range the layout can survive")
    func scalesAreClamped() throws {
        let settings = try makeSettings()

        settings.textScale = 10
        #expect(settings.textScale == 2)
        settings.textScale = 0
        #expect(settings.textScale == 0.75)

        settings.thumbnailScale = 99
        #expect(settings.thumbnailScale == 2)
    }

    @Test("a written preference is read back")
    func roundTrip() throws {
        let settings = try makeSettings()

        settings.mediaLoadPolicy = .wifiOnly
        settings.appearance = .dark
        settings.downloadConflictAction = .skip
        settings.themeID = "solarized"
        settings.catalogByDefault = false

        #expect(settings.mediaLoadPolicy == .wifiOnly)
        #expect(settings.appearance == .dark)
        #expect(settings.downloadConflictAction == .skip)
        #expect(settings.themeID == "solarized")
        #expect(settings.catalogByDefault == false)
    }

    @Test("the auto refresh interval is either off or at least fifteen seconds")
    func autoRefreshFloor() throws {
        let settings = try makeSettings()

        settings.autoRefreshIntervalSeconds = 0
        #expect(settings.autoRefreshIntervalSeconds == 0)
        settings.autoRefreshIntervalSeconds = 3
        #expect(settings.autoRefreshIntervalSeconds == 15)
    }
}

/// Preferences are computed properties over `UserDefaults`, and `@Observable`
/// only tracks stored ones. Without a stored value behind them a change never
/// reaches the views, and a setting appears to do nothing until the screen is
/// rebuilt for some other reason.
@MainActor
@Suite("App settings observation")
struct AppSettingsObservationTests {
    private func makeSettings() throws -> AppSettings {
        let name = "neechan.tests.\(UUID().uuidString)"
        return AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
    }

    @Test("changing a preference tells anyone observing it")
    func changeIsObserved() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.appearance
        } onChange: {
            observed.raise()
        }

        settings.appearance = .dark
        #expect(observed.wasRaised, "the appearance change was not observed")
    }

    @Test(
        "every kind of preference is observed, not just the ones with a stored default",
        arguments: [
            "domain", "themeID", "textScale", "collapsePostLineLimit",
            "mediaLoadPolicy", "remembersHistory", "nsfwMode", "locksApp",
            "allowsMatureBoards",
        ]
    )
    func everyPreferenceIsObserved(name: String) throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            switch name {
            case "domain": _ = settings.domain
            case "themeID": _ = settings.themeID
            case "textScale": _ = settings.textScale
            case "collapsePostLineLimit": _ = settings.collapsePostLineLimit
            case "mediaLoadPolicy": _ = settings.mediaLoadPolicy
            case "remembersHistory": _ = settings.remembersHistory
            case "locksApp": _ = settings.locksApp
            case "allowsMatureBoards": _ = settings.allowsMatureBoards
            default: _ = settings.nsfwMode
            }
        } onChange: {
            observed.raise()
        }

        switch name {
        case "domain": settings.domain = .life
        case "themeID": settings.themeID = "x"
        case "textScale": settings.textScale = 1.5
        case "collapsePostLineLimit": settings.collapsePostLineLimit = 5
        case "mediaLoadPolicy": settings.mediaLoadPolicy = .never
        case "remembersHistory": settings.remembersHistory = false
        case "locksApp": settings.locksApp = true
        case "allowsMatureBoards": settings.allowsMatureBoards = false
        default: settings.nsfwMode = true
        }

        #expect(observed.wasRaised, "\(name) was changed without telling anyone")
    }

    @Test("reading a preference twice does not itself count as a change")
    func readingIsNotAChange() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.textScale
        } onChange: {
            observed.raise()
        }

        _ = settings.textScale
        _ = settings.thumbnailScale
        #expect(observed.wasRaised == false)
    }
}

@MainActor
@Suite("Preference isolation")
struct PreferenceIsolationTests {
    private func makeSettings() throws -> AppSettings {
        let name = "neechan.tests.\(UUID().uuidString)"
        return AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
    }

    /// The counters are written while the reader is reading — every thread
    /// opened, every trip to the background — and every post cell on screen
    /// reads the text scale. Sharing one observation key between them meant
    /// each of those writes redrew the whole thread.
    @Test("counting a thread opened does not disturb a reader of the text scale")
    func statisticsAreSeparate() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.textScale
        } onChange: {
            observed.raise()
        }

        settings.recordThreadOpened()
        settings.addTimeInApp(seconds: 5)
        settings.recordPostSent()

        #expect(observed.wasRaised == false)
    }

    @Test("changing one preference does not disturb a reader of another")
    func preferencesAreSeparate() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.textScale
        } onChange: {
            observed.raise()
        }

        settings.thumbnailScale = 1.5
        settings.nsfwMode = true
        settings.collapsePostLineLimit = 20

        #expect(observed.wasRaised == false)
    }

    @Test("writing a preference its current value disturbs nobody")
    func unchangedWritesAreQuiet() throws {
        let settings = try makeSettings()
        settings.textScale = 1.5
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.textScale
        } onChange: {
            observed.raise()
        }

        settings.textScale = 1.5

        #expect(observed.wasRaised == false)
    }

    @Test("a value already in the defaults is read when the settings are built")
    func storedValuesSurviveConstruction() throws {
        let name = "neechan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(1.5, forKey: "interface.textScale")
        defaults.set(20, forKey: "interface.collapseLines")
        defaults.set(true, forKey: "restrictions.nsfwMode")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.textScale == 1.5)
        #expect(settings.collapsePostLineLimit == 20)
        #expect(settings.nsfwMode)
    }

    /// How a UI test pins a preference: launch arguments arrive as strings, and
    /// an `as?` cast to the stored type drops them silently.
    @Test("a numeric preference pinned as a string is still read")
    func stringsAreCoerced() throws {
        let name = "neechan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set("1.5", forKey: "interface.textScale")
        defaults.set("20", forKey: "interface.collapseLines")
        defaults.set("30", forKey: "contents.autoRefresh")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.textScale == 1.5)
        #expect(settings.collapsePostLineLimit == 20)
        #expect(settings.autoRefreshIntervalSeconds == 30)
    }
}

@MainActor
@Suite("Media cache limit")
struct MediaCacheLimitTests {
    private func makeSettings() throws -> AppSettings {
        let name = "neechan.tests.\(UUID().uuidString)"
        return AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
    }

    @Test("a fresh install starts on the smallest of the sizes on offer")
    func startsSmall() throws {
        #expect(try makeSettings().mediaCacheLimitMegabytes == 5 * 1024)
    }

    @Test("every size on offer is kept exactly as chosen")
    func choicesRoundTrip() throws {
        let settings = try makeSettings()
        for choice in AppSettings.cacheLimitChoicesMegabytes {
            settings.mediaCacheLimitMegabytes = choice
            #expect(settings.mediaCacheLimitMegabytes == choice)
        }
    }

    /// The settings screen shows one of four sizes and the cache enforces what
    /// is stored. If those could differ, the screen would be lying.
    @Test("anything else becomes the nearest size on offer")
    func othersSnap() throws {
        let settings = try makeSettings()

        settings.mediaCacheLimitMegabytes = 6 * 1024
        #expect(settings.mediaCacheLimitMegabytes == 5 * 1024)

        settings.mediaCacheLimitMegabytes = 16 * 1024
        #expect(settings.mediaCacheLimitMegabytes == 20 * 1024)

        settings.mediaCacheLimitMegabytes = 1_000 * 1024
        #expect(settings.mediaCacheLimitMegabytes == 50 * 1024)

        settings.mediaCacheLimitMegabytes = 0
        #expect(settings.mediaCacheLimitMegabytes == 5 * 1024)
    }

    /// What an install from before these sizes existed has stored.
    @Test("a size left by an older version reads as the nearest one")
    func oldValuesAreRead() throws {
        let name = "neechan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(512, forKey: "media.cacheLimit")

        #expect(AppSettings(defaults: defaults).mediaCacheLimitMegabytes == 5 * 1024)
    }
}

@MainActor
@Suite("Media cache age")
struct MediaCacheAgeTests {
    private func makeSettings() throws -> AppSettings {
        let name = "neechan.tests.\(UUID().uuidString)"
        return AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
    }

    /// Long enough for a thread followed over weeks, short enough that a phone
    /// is not carrying last spring's clips around.
    @Test("a fresh install keeps cached media for a month")
    func startsAtAMonth() throws {
        #expect(try makeSettings().mediaCacheMaxAgeDays == 30)
    }

    @Test("every length on offer is kept exactly as chosen")
    func choicesRoundTrip() throws {
        let settings = try makeSettings()
        for choice in AppSettings.cacheAgeChoicesDays {
            settings.mediaCacheMaxAgeDays = choice
            #expect(settings.mediaCacheMaxAgeDays == choice)
        }
    }

    /// Snapped by membership rather than to the nearest number: forever is
    /// stored as zero, and zero is not close to one day, it is the opposite.
    @Test("anything else falls back to the length a fresh install has")
    func othersFallBack() throws {
        let settings = try makeSettings()
        settings.mediaCacheMaxAgeDays = 7
        #expect(settings.mediaCacheMaxAgeDays == 7)

        // Forever is a stop on the slider, not a stray value.
        settings.mediaCacheMaxAgeDays = 0
        #expect(settings.mediaCacheMaxAgeDays == 0)

        settings.mediaCacheMaxAgeDays = 3
        #expect(settings.mediaCacheMaxAgeDays == 30)

        settings.mediaCacheMaxAgeDays = -5
        #expect(settings.mediaCacheMaxAgeDays == 30)
    }

    @Test("a length left by an older version is not trusted")
    func oldValuesAreRead() throws {
        let name = "neechan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(90, forKey: "media.cacheMaxAge")

        #expect(AppSettings(defaults: defaults).mediaCacheMaxAgeDays == 30)
    }
}

/// `withObservationTracking`'s change handler runs outside the caller's
/// isolation, so the flag it sets has to be one a closure can cross into.
final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.withLock { raised = true }
    }

    var wasRaised: Bool {
        lock.withLock { raised }
    }
}

@MainActor
@Suite("Board layout memory")
struct ThreadsViewModeTests {
    private func makeSettings() throws -> AppSettings {
        let name = "neechan.tests.\(UUID().uuidString)"
        return AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
    }

    @Test("a board opens as cards until the reader says otherwise")
    func defaultLayout() throws {
        #expect(try makeSettings().threadsViewMode(forBoard: "b") == .cards)
    }

    @Test("a layout chosen on a board is remembered for that board")
    func remembersPerBoard() throws {
        let settings = try makeSettings()

        settings.setThreadsViewMode(.grid, forBoard: "b")
        #expect(settings.threadsViewMode(forBoard: "b") == .grid)
    }

    /// A media board wants a grid and a text board wants a list, so the choice
    /// is kept per board rather than as one setting for the whole app.
    @Test("two boards keep their own layouts")
    func boardsAreIndependent() throws {
        let settings = try makeSettings()

        settings.setThreadsViewMode(.grid, forBoard: "b")
        settings.setThreadsViewMode(.list, forBoard: "po")

        #expect(settings.threadsViewMode(forBoard: "b") == .grid)
        #expect(settings.threadsViewMode(forBoard: "po") == .list)
    }

    /// Opening a board for the first time should feel like the app the reader
    /// has been using, not like a fresh install.
    @Test("a board never opened before follows the last choice made anywhere")
    func newBoardsFollowTheLastChoice() throws {
        let settings = try makeSettings()

        settings.setThreadsViewMode(.list, forBoard: "b")
        #expect(settings.threadsViewMode(forBoard: "vg") == .list)
    }

    @Test("the choice is observed, so the list redraws when it changes")
    func choiceIsObserved() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.threadsViewMode(forBoard: "b")
        } onChange: {
            observed.raise()
        }

        settings.setThreadsViewMode(.grid, forBoard: "b")
        #expect(observed.wasRaised)
    }
}

@MainActor
@Suite("Language")
struct LanguageSettingTests {
    private func makeSettings() throws -> AppSettings {
        AppSettings(defaults: try #require(UserDefaults(suiteName: "neechan.tests.\(UUID().uuidString)")))
    }

    @Test("the app follows the system language until told otherwise")
    func defaultsToSystem() throws {
        #expect(try makeSettings().languageCode == nil)
    }

    @Test("a chosen language is remembered and observed")
    func remembersChoice() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.languageCode
        } onChange: {
            observed.raise()
        }

        settings.languageCode = "ru"
        #expect(settings.languageCode == "ru")
        #expect(observed.wasRaised)
    }

    @Test(
        "the word system, and an empty value, both mean follow the system",
        arguments: ["system", ""]
    )
    func systemSentinel(value: String) throws {
        let settings = try makeSettings()
        settings.languageCode = value
        #expect(settings.languageCode == nil)
    }

    @Test("choosing the system language again clears it")
    func clearing() throws {
        let settings = try makeSettings()
        settings.languageCode = "en"
        settings.languageCode = nil
        #expect(settings.languageCode == nil)
    }
}

@MainActor
@Suite("Statistics")
struct StatisticsTests {
    private func makeSettings() throws -> AppSettings {
        AppSettings(defaults: try #require(UserDefaults(suiteName: "neechan.tests.\(UUID().uuidString)")))
    }

    @Test("a fresh install has counted nothing")
    func startsEmpty() throws {
        let statistics = try makeSettings().statistics

        #expect(statistics.secondsInApp == 0)
        #expect(statistics.postsSent == 0)
        #expect(statistics.threadsOpened == 0)
    }

    @Test("time in the app adds up across sessions")
    func timeAccumulates() throws {
        let settings = try makeSettings()

        settings.addTimeInApp(seconds: 30)
        settings.addTimeInApp(seconds: 12.5)

        #expect(settings.statistics.secondsInApp == 42.5)
    }

    /// A session that ran overnight in the background would otherwise land as
    /// hours of "use" the reader never had.
    @Test("an absurdly long stretch is not counted")
    func ignoresImplausibleStretches() throws {
        let settings = try makeSettings()

        settings.addTimeInApp(seconds: 60 * 60 * 9)
        #expect(settings.statistics.secondsInApp == 0)
    }

    @Test("negative time is ignored")
    func ignoresNegativeTime() throws {
        let settings = try makeSettings()
        settings.addTimeInApp(seconds: -100)
        #expect(settings.statistics.secondsInApp == 0)
    }

    @Test("posts and threads are counted one at a time")
    func counters() throws {
        let settings = try makeSettings()

        settings.recordPostSent()
        settings.recordPostSent()
        settings.recordThreadOpened()

        #expect(settings.statistics.postsSent == 2)
        #expect(settings.statistics.threadsOpened == 1)
    }

    @Test("counting is observed, so an open statistics screen updates")
    func countingIsObserved() throws {
        let settings = try makeSettings()
        let observed = ChangeFlag()

        withObservationTracking {
            _ = settings.statistics
        } onChange: {
            observed.raise()
        }

        settings.recordPostSent()
        #expect(observed.wasRaised)
    }

    @Test("the counters can be reset")
    func reset() throws {
        let settings = try makeSettings()
        settings.recordPostSent()
        settings.addTimeInApp(seconds: 10)

        settings.resetStatistics()

        #expect(settings.statistics.postsSent == 0)
        #expect(settings.statistics.secondsInApp == 0)
    }
}

@Suite("Random upload names")
struct RandomFileNameTests {
    @Test("a name is sixteen hex characters")
    func shape() {
        let name = AppSettings.randomFileName()

        #expect(name.count == 16)
        #expect(name.allSatisfy { $0.isHexDigit })
        #expect(name.allSatisfy { !$0.isUppercase })
    }

    /// Two files attached to the same post must not collide, and a name must
    /// say nothing about what it replaced.
    @Test("two names differ")
    func uniqueness() {
        let names = Set((0..<200).map { _ in AppSettings.randomFileName() })
        #expect(names.count == 200)
    }
}

/// Carrying `interface.safeForWork` into `nsfwMode`, which means the opposite.
///
/// The awkward case is a reader who never touched the old toggle: there is no
/// value to invert, and the new default would reverse what they have been
/// seeing. Each test here is one row of that table.
@MainActor
@Suite("Safe for work becomes NSFW mode")
struct NSFWModeMigrationTests {
    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "neechan.tests.\(UUID().uuidString)"))
    }

    @Test("a reader who turned safe for work on keeps their blur")
    func safeForWorkOnMeansNSFWModeOff() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: "interface.safeForWork")

        #expect(AppSettings(defaults: defaults).nsfwMode == false)
    }

    @Test("a reader who turned it off explicitly keeps their unblurred thumbnails")
    func safeForWorkOffMeansNSFWModeOn() throws {
        let defaults = try freshDefaults()
        defaults.set(false, forKey: "interface.safeForWork")

        #expect(AppSettings(defaults: defaults).nsfwMode)
    }

    /// The row that needs the probe: nothing was ever stored for this reader,
    /// but they have been using the app and seeing unblurred thumbnails.
    @Test("a reader who never touched it, but has used the app, keeps what they had")
    func anUpgradeKeepsTodaysBehaviour() throws {
        let defaults = try freshDefaults()
        defaults.set(12, forKey: "stats.threadsOpened")

        #expect(AppSettings(defaults: defaults).nsfwMode)
    }

    @Test("a fresh install gets the new default, which blurs")
    func aFreshInstallBlurs() throws {
        #expect(AppSettings(defaults: try freshDefaults()).nsfwMode == false)
    }

    /// The migration must not be able to undo a choice made after it ran.
    @Test("a choice made after the migration survives the next launch")
    func theMigrationRunsOnlyOnce() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: "interface.safeForWork")

        let first = AppSettings(defaults: defaults)
        #expect(first.nsfwMode == false)
        first.nsfwMode = true

        #expect(AppSettings(defaults: defaults).nsfwMode, "the migration ran a second time")
    }

    @Test("the old key is not left behind to be migrated again")
    func theLegacyKeyIsCleanedUp() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: "interface.safeForWork")
        _ = AppSettings(defaults: defaults)

        #expect(defaults.object(forKey: "interface.safeForWork") == nil)
    }

    @Test("the two new gates are open until the reader closes them")
    func theGatesDefaultOpen() throws {
        let settings = AppSettings(defaults: try freshDefaults())
        #expect(settings.allowsMatureBoards)
        #expect(settings.allowsPosting)
    }
}

/// The build meant for the App Store.
///
/// It changes two things: boards for adults start hidden rather than shown, and
/// posting is off and stays off. Everything else is the same app.
@MainActor
@Suite("The App Store build")
struct AppStoreBuildTests {
    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "neechan.tests.\(UUID().uuidString)"))
    }

    private func appStoreSettings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, isAppStoreBuild: true)
    }

    // MARK: Reading the flag out of the bundle

    /// The case that matters most is the empty string: an undefined build
    /// setting expands to nothing, and nothing must mean the ordinary build.
    @Test(
        "the plist value is read the way Xcode writes it",
        arguments: [
            ("YES", true), ("yes", true), ("true", true), ("1", true),
            ("NO", false), ("no", false), ("false", false), ("0", false),
            ("", false),
        ]
    )
    func readsTheFlag(value: String, expected: Bool) {
        #expect(BuildVariant.isAppStore(in: [BuildVariant.key: value]) == expected)
    }

    @Test("a missing key is the ordinary build")
    func aMissingKeyIsOrdinary() {
        #expect(!BuildVariant.isAppStore(in: [:]))
        #expect(!BuildVariant.isAppStore(in: nil))
        #expect(!BuildVariant.isAppStore(in: ["SomethingElse": "YES"]))
    }

    /// A plist edited by hand says `<true/>`, which is neither a string nor a
    /// number as far as Swift is concerned until it is asked nicely.
    @Test("a real boolean in the plist is read too")
    func readsABoolean() {
        #expect(BuildVariant.isAppStore(in: [BuildVariant.key: true]))
        #expect(!BuildVariant.isAppStore(in: [BuildVariant.key: false]))
        #expect(BuildVariant.isAppStore(in: [BuildVariant.key: NSNumber(value: 1)]))
    }

    /// Under `swift test` the main bundle is the runner, so the app's own key
    /// is not there and everything else in this file behaves as it always has.
    @Test("a test is never the App Store build")
    func testsAreNotTheAppStoreBuild() {
        #expect(!BuildVariant.isAppStore)
    }

    // MARK: Posting, which is not a preference at all

    @Test("posting is off")
    func postingIsOff() throws {
        #expect(!appStoreSettings(try freshDefaults()).allowsPosting)
    }

    /// The closest a unit test can get to the launch-argument case, which is
    /// the one that matters: `bool(_:default:)` honours the argument domain on
    /// purpose, so a preference could be pinned back on from the command line.
    /// An argument domain cannot be injected into a `UserDefaults(suiteName:)`
    /// at all, so the persistent domain stands in for it — if a stored `true`
    /// under the old key cannot win, nothing can, because nothing is read.
    @Test("a value stored under the retired key does not turn posting back on")
    func aStoredValueDoesNotWin() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: "posting.enabled")

        #expect(!appStoreSettings(defaults).allowsPosting)
    }

    /// Nothing reads or writes it any more, so a reader who had turned posting
    /// off in an earlier version is not quietly kept from posting for ever.
    @Test("the retired preference is ignored in the ordinary build too")
    func theRetiredKeyIsIgnoredEverywhere() throws {
        let defaults = try freshDefaults()
        defaults.set(false, forKey: "posting.enabled")

        #expect(AppSettings(defaults: defaults, isAppStoreBuild: false).allowsPosting)
    }

    // MARK: The agreement

    @Test("the terms have not been agreed to on a fresh install")
    func termsStartUnagreed() throws {
        #expect(!appStoreSettings(try freshDefaults()).hasAgreedToTerms)
    }

    /// Asked once. A reader who agreed and then relaunched into the agreement
    /// again would reasonably conclude the button does nothing.
    @Test("agreeing is remembered across a relaunch")
    func agreeingSticks() throws {
        let defaults = try freshDefaults()
        appStoreSettings(defaults).hasAgreedToTerms = true

        #expect(appStoreSettings(defaults).hasAgreedToTerms)
    }

    /// Only this build asks, but the flag is an ordinary preference in both, so
    /// a test pointed at either can pin it.
    @Test("the ordinary build stores it the same way")
    func theOrdinaryBuildStoresItToo() throws {
        let settings = AppSettings(defaults: try freshDefaults(), isAppStoreBuild: false)
        #expect(!settings.hasAgreedToTerms)

        settings.hasAgreedToTerms = true
        #expect(settings.hasAgreedToTerms)
    }

    // MARK: The two that only start differently

    @Test("boards for adults start hidden")
    func matureStartsOff() throws {
        #expect(!appStoreSettings(try freshDefaults()).allowsMatureBoards)
    }

    /// Deliberately not a lock. This is the assertion that stops someone
    /// "finishing the job" later by fixing it the way posting is fixed.
    @Test("the reader can still show boards for adults")
    func matureCanStillBeTurnedOn() throws {
        let defaults = try freshDefaults()
        let settings = appStoreSettings(defaults)

        settings.allowsMatureBoards = true
        #expect(settings.allowsMatureBoards)
        // And it stays on, rather than being reset on the next launch.
        #expect(appStoreSettings(defaults).allowsMatureBoards)
    }

    /// True of the ordinary build as well; asserted here so that the cautious
    /// start is something this build promises rather than something it inherits
    /// by luck from a default that might later move.
    @Test("thumbnails start blurred")
    func nsfwStartsOff() throws {
        let settings = appStoreSettings(try freshDefaults())
        #expect(!settings.nsfwMode)

        settings.nsfwMode = true
        #expect(settings.nsfwMode, "NSFW mode is a preference here, not a lock")
    }

    @Test("the ordinary build is unchanged")
    func theOrdinaryBuildIsUnchanged() throws {
        let settings = AppSettings(defaults: try freshDefaults(), isAppStoreBuild: false)

        #expect(settings.allowsPosting)
        #expect(settings.allowsMatureBoards)
    }
}

/// Where a link off the imageboard opens.
///
/// Two preferences decide it, and the age gate is the one that wins: an in-app
/// browser is a surface the app answers for, and it will follow wherever a link
/// a stranger wrote goes. Until the reader has said they are 18, links leave.
@MainActor
@Suite("Links off the imageboard")
struct ExternalLinkDestinationTests {
    private func makeSettings(isAppStoreBuild: Bool = false) throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "neechan.tests.\(UUID().uuidString)"))
        return AppSettings(defaults: defaults, isAppStoreBuild: isAppStoreBuild)
    }

    @Test(
        "the in-app browser needs the preference and the age together",
        arguments: [
            (true, true, true),
            (true, false, false),
            (false, true, false),
            (false, false, false),
        ]
    )
    func bothConditionsAreRequired(
        usesInternalBrowser: Bool, allowsMature: Bool, expected: Bool
    ) throws {
        let settings = try makeSettings()
        settings.usesInternalBrowser = usesInternalBrowser
        settings.allowsMatureBoards = allowsMature

        #expect(settings.opensLinksInApp == expected)
    }

    /// The ordinary build starts with the age confirmed, so this is the one
    /// case where nothing changed: links keep opening in the app.
    @Test("the ordinary build opens links in the app out of the box")
    func ordinaryBuildIsUnchanged() throws {
        let settings = try makeSettings()

        #expect(settings.usesInternalBrowser)
        #expect(settings.allowsMatureBoards)
        #expect(settings.opensLinksInApp)
    }

    /// The App Store build starts with the age unconfirmed, so it starts by
    /// handing links to Safari -- while the preference itself is still on, and
    /// still says so once the reader answers the gate.
    @Test("the App Store build sends links to Safari until the age is confirmed")
    func appStoreBuildLeavesUntilConfirmed() throws {
        let settings = try makeSettings(isAppStoreBuild: true)

        #expect(settings.usesInternalBrowser)
        #expect(!settings.allowsMatureBoards)
        #expect(!settings.opensLinksInApp)

        settings.allowsMatureBoards = true
        #expect(settings.opensLinksInApp)
    }

    /// Turning the gate off again takes the browser back with it, rather than
    /// leaving the reader with what they had before they answered.
    @Test("turning the age gate back off sends links out again")
    func revokingTheAgeTakesItBack() throws {
        let settings = try makeSettings()
        settings.allowsMatureBoards = false

        #expect(!settings.opensLinksInApp)
        #expect(settings.usesInternalBrowser, "the reader's own preference was overwritten")
    }
}

/// Which notification modes a build offers, and what happens to a stored mode
/// it does not.
///
/// The watcher itself is a reading feature and is the same in both builds; only
/// "Replies to me" is build-dependent, because it needs posts of the reader's
/// own for a reply to arrive at.
@MainActor
@Suite("Watcher notification modes")
struct WatcherNotificationChoiceTests {
    private func makeSettings(isAppStoreBuild: Bool) throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "neechan.tests.\(UUID().uuidString)"))
        return AppSettings(defaults: defaults, isAppStoreBuild: isAppStoreBuild)
    }

    @Test("a build that can post offers every mode")
    func ordinaryBuildOffersAll() throws {
        let settings = try makeSettings(isAppStoreBuild: false)

        #expect(settings.watcherNotificationChoices == WatcherNotificationSetting.allCases)
        #expect(settings.watcherNotifications == .repliesOnly, "the default moved")
    }

    @Test("a build that cannot post leaves out replies to me")
    func appStoreBuildLeavesOutRepliesOnly() throws {
        let settings = try makeSettings(isAppStoreBuild: true)

        #expect(settings.watcherNotificationChoices == [.off, .allNewPosts])
        #expect(!settings.watcherNotificationChoices.contains(.repliesOnly))
    }

    /// The stored default *is* the mode that build does not offer, so without
    /// narrowing a fresh install would sit on it and the picker would have no
    /// matching tag to draw.
    @Test("the unoffered default reads as off rather than as itself")
    func theDefaultIsNarrowed() throws {
        let settings = try makeSettings(isAppStoreBuild: true)

        #expect(settings.watcherNotifications == .off)
    }

    /// The same narrowing for a value that was chosen rather than defaulted —
    /// a backup restored from the other build, say.
    @Test("a stored mode the build does not offer reads as off")
    func storedRepliesOnlyIsNarrowed() throws {
        let settings = try makeSettings(isAppStoreBuild: true)
        settings.watcherNotifications = .repliesOnly

        #expect(settings.watcherNotifications == .off)
    }

    /// Narrowed towards quiet, not towards noise: coercing to `.allNewPosts`
    /// would hand the reader more notifications than they ever asked for.
    @Test("the modes the build does offer are untouched")
    func offeredModesRoundTrip() throws {
        let settings = try makeSettings(isAppStoreBuild: true)

        for mode in [WatcherNotificationSetting.allNewPosts, .off] {
            settings.watcherNotifications = mode
            #expect(settings.watcherNotifications == mode, "\(mode) did not round-trip")
        }
    }
}
