import Foundation
import Testing
@testable import Neechan
import NeechanSettings
import NeechanUI
import NeechanAPI

@Suite("App shell")
@MainActor
struct AppShellTests {
    /// The imageboard switcher is a toolbar control, not a fifth tab: the tab
    /// bar is mirrored whole so its minimised pill lands under the thumb, and
    /// another tab would change that geometry.
    @Test("the shell declares every top-level section")
    func tabsAreComplete() {
        #expect(AppTab.allCases == [.boards, .favorites, .history, .settings])
        #expect(AppTab.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    @Test("settings default to the primary mirror")
    func defaultDomain() {
        let defaults = UserDefaults(suiteName: "AppShellTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.domain == .org)
        #expect(settings.snapshot.domain == .org)
    }

    @Test("switching the mirror is persisted")
    func domainRoundTrips() {
        let suite = "AppShellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        AppSettings(defaults: defaults).domain = .life
        #expect(AppSettings(defaults: defaults).domain == .life)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("settings default to 4chan")
    func defaultImageboard() {
        let defaults = UserDefaults(suiteName: "AppShellTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.imageboard == .fourchan)
        #expect(settings.snapshot.imageboard == .fourchan)
    }

    @Test("switching the imageboard is persisted")
    func imageboardRoundTrips() {
        let suite = "AppShellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        AppSettings(defaults: defaults).imageboard = .fourchan
        #expect(AppSettings(defaults: defaults).imageboard == .fourchan)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The raw values are the `siteRaw` column on every stored record, and the
    /// value the store backfills rows written before there were two sites.
    /// Renaming a case would silently orphan every favourite on the device.
    @Test("the stored names of the imageboards are pinned")
    func rawValuesArePinned() {
        #expect(Imageboard.dvach.rawValue == "dvach")
        #expect(Imageboard.fourchan.rawValue == "fourchan")
    }
}
