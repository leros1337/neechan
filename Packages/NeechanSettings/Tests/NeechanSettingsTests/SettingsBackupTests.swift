import Foundation
import Testing
@testable import NeechanSettings

/// What a backup carries of the settings and statistics, and what an import
/// does with them.
///
/// The regression: a backup carried none of it. Export handed the backup an
/// empty dictionary and import never looked at one, so a reader moving to a new
/// phone got their favourites back and every preference reset.
@MainActor
@Suite("Settings in a backup")
struct SettingsBackupTests {
    private func makeSettings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "neechan.backup.\(UUID().uuidString)"))
        return AppSettings(defaults: defaults, isAppStoreBuild: false, isRestrictedBuild: false)
    }

    @Test("every preference a reader changed reaches the other device")
    func preferencesRoundTrip() throws {
        let source = try makeSettings()
        source.textScale = 1.3
        source.thumbnailScale = 0.8
        source.imageboard = .fourchan
        source.domain = .life
        source.appearance = .dark
        source.defaultBoard = "b"
        source.setThreadsViewMode(.grid, forBoard: "b")
        source.allowsMatureBoards = false
        source.nsfwMode = true
        source.collapsePostLineLimit = 30
        source.autoRefreshIntervalSeconds = 60
        source.videoLoops = true
        source.downloadSubdirectoryPattern = "<board>"
        source.mediaCacheLimitMegabytes = AppSettings.cacheLimitChoicesMegabytes.last!
        let password = source.postDeletionPassword

        let target = try makeSettings()
        target.applyBackupPreferences(source.backupPreferences())

        // The ones read while drawing are held in stored properties, so these
        // also say the screen sees the change without a relaunch.
        #expect(target.textScale == 1.3)
        #expect(target.thumbnailScale == 0.8)
        #expect(target.imageboard == .fourchan)
        #expect(target.domain == .life)
        #expect(target.nsfwMode)
        #expect(target.collapsePostLineLimit == 30)
        #expect(target.autoRefreshIntervalSeconds == 60)

        #expect(target.appearance == .dark)
        #expect(target.defaultBoard == "b")
        #expect(target.threadsViewMode(forBoard: "b") == .grid)
        #expect(target.allowsMatureBoards == false)
        #expect(target.videoLoops)
        #expect(target.downloadSubdirectoryPattern == "<board>")
        #expect(target.mediaCacheLimitMegabytes == AppSettings.cacheLimitChoicesMegabytes.last!)
        // Without it, the new device cannot delete a post the old one made.
        #expect(target.postDeletionPassword == password)
    }

    @Test("what belongs to one device stays on it")
    func deviceOnlyPreferencesStay() throws {
        let source = try makeSettings()
        // A bookmark to a folder only means something on the device that made
        // it; the lock and the terms are the reader's answer on this device.
        source.downloadFolderBookmark = Data([1, 2, 3])
        source.locksApp = true
        source.hasAgreedToTerms = true
        source.recordThreadOpened()

        let backup = source.backupPreferences()
        let target = try makeSettings()
        target.applyBackupPreferences(backup)

        #expect(target.downloadFolderBookmark == nil)
        #expect(target.locksApp == false)
        #expect(target.hasAgreedToTerms == false)
        // Statistics travel separately, merged rather than overwritten.
        #expect(target.statistics.threadsOpened == 0)
        for key in backup.values.keys {
            #expect(!key.hasPrefix("stats."), "\(key) went with the preferences")
        }
    }

    /// Taking the backup's settings means taking its defaults as well: a
    /// preference the other device never changed is reset here.
    @Test("a preference left at its default there is reset here")
    func unsetPreferencesReset() throws {
        let source = try makeSettings()
        let target = try makeSettings()
        target.textScale = 1.5
        target.videoLoops = true

        target.applyBackupPreferences(source.backupPreferences())

        #expect(target.textScale == 1)
        #expect(target.videoLoops == false)
    }

    /// Changing the imageboard has to go through `AppServices.select`, which
    /// re-points the client before the setting is seen; an import asks which
    /// one the backup will leave it on so it can do that first.
    @Test("the imageboard a backup leaves the app on can be told beforehand")
    func imageboardAfterBackup() throws {
        let source = try makeSettings()
        let target = try makeSettings()
        #expect(target.imageboard(after: source.backupPreferences()) == .default)

        source.imageboard = .fourchan
        #expect(target.imageboard(after: source.backupPreferences()) == .fourchan)

        // An older file says nothing about it, and nothing should move.
        target.imageboard = .fourchan
        #expect(target.imageboard(after: PreferencesBackup()) == .fourchan)
    }

    @Test("statistics are merged, so importing twice does not double them")
    func statisticsMerge() throws {
        let settings = try makeSettings()
        for _ in 0..<5 { settings.recordThreadOpened() }
        settings.addTimeInApp(seconds: 100)

        let backup = UsageStatistics(secondsInApp: 400, postsSent: 2, threadsOpened: 3)
        settings.mergeStatistics(backup)
        settings.mergeStatistics(backup)

        #expect(settings.statistics.threadsOpened == 5, "a device's own count is never lowered")
        #expect(settings.statistics.secondsInApp == 400)
        #expect(settings.statistics.postsSent == 2)
    }

    /// The file is meant to be readable, so a value is written as itself rather
    /// than wrapped in the enum's case name.
    @Test("a preference is written as the plain value")
    func preferenceValueCoding() throws {
        let values: [String: PreferenceValue] = [
            "b": .bool(true), "i": .int(3), "d": .double(1.5),
            "s": .string("x"), "m": .strings(["b": "grid"])
        ]
        let data = try JSONEncoder().encode(values)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"b\":true"))
        #expect(json.contains("\"i\":3"))
        #expect(json.contains("\"d\":1.5"))
        #expect(json.contains("\"m\":{\"b\":\"grid\"}"))

        #expect(try JSONDecoder().decode([String: PreferenceValue].self, from: data) == values)
    }
}
