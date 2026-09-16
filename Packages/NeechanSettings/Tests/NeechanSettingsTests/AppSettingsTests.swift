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
        #expect(settings.thumbnailScale == 1)
        #expect(settings.remembersHistory)
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
            "mediaLoadPolicy", "remembersHistory", "safeForWork",
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
            default: _ = settings.safeForWork
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
        default: settings.safeForWork = true
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
        settings.safeForWork = true
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
        defaults.set(true, forKey: "interface.safeForWork")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.textScale == 1.5)
        #expect(settings.collapsePostLineLimit == 20)
        #expect(settings.safeForWork)
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
