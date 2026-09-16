import Foundation
import Testing
@testable import Neechan
import NeechanSettings
import NeechanUI
import NeechanAPI

@Suite("App shell")
@MainActor
struct AppShellTests {
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
}
