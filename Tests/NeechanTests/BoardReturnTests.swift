import Foundation
import NeechanAPI
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import NeechanUI
import SwiftUI
import Testing
import UIKit

/// What coming back to a board costs.
///
/// Hosted in the app on the simulator rather than run as a package test,
/// because what is being pinned is SwiftUI's: it runs a view's `task` again
/// every time the view comes back into sight, from a thread pushed over it or
/// from another tab, with its key unchanged. The board loaded in that task, so
/// every return fetched it again and moved the rows the reader came back to.
@Suite("Coming back to a board")
@MainActor
struct BoardReturnTests {
    private let thread = ThreadKey(site: .dvach, board: "po", threadNum: 63459413)

    @Test("coming back from a thread or another tab does not fetch the board again")
    func returningDoesNotRefetch() async throws {
        try await withBoard { router, transport in
            router.boardsPath.append(.thread(thread, scrollTo: nil))
            try await settle()
            router.boardsPath.removeLast()
            try await settle()
            #expect(await transport.catalogFetches == 1, "back from a thread")

            router.selectedTab = .favorites
            try await settle()
            router.selectedTab = .boards
            try await settle()
            #expect(await transport.catalogFetches == 1, "back from another tab")
        }
    }

    /// The setting brings the refresh back, and only for a list that has gone
    /// stale. Fifteen seconds is the shortest window the setting allows.
    @Test("with the setting on, coming back to a stale board fetches it once")
    func settingRefreshesAStaleBoard() async throws {
        try await withBoard(configure: { settings in
            settings.refreshesBoardsOnReturn = true
            settings.watcherIntervalSeconds = 15
            settings.watcherWiFiOnly = false
        }) { router, transport in
            router.boardsPath.append(.thread(thread, scrollTo: nil))
            try await Task.sleep(for: .seconds(16))
            router.boardsPath.removeLast()
            try await waitUntil { await transport.catalogFetches == 2 }
            try await settle()
            #expect(await transport.catalogFetches == 2)
        }
    }

    /// Opens /po/ in the app's own tab shell and waits for its first fetch.
    private func withBoard(
        configure: (AppSettings) -> Void = { _ in },
        _ body: (Router, CountingTransport) async throws -> Void
    ) async throws {
        let suite = "BoardReturnTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.imageboard = .dvach
        configure(settings)
        let transport = CountingTransport()
        let services = try AppServices.inMemory(settings: settings, transport: transport)
        let router = Router()

        let window = try host(RootTabView().environment(router).environment(services))
        defer { window.isHidden = true }

        router.boardsPath = [.board("po")]
        try await waitUntil { await transport.catalogFetches == 1 }
        try await body(router, transport)
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// Long enough for a push or a pop to finish and anything it starts to
    /// reach the transport.
    private func settle() async throws {
        try await Task.sleep(for: .seconds(1.5))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out")
    }
}

/// Answers from the recorded /po/ fixtures and counts the catalog requests.
private actor CountingTransport: HTTPTransport {
    private(set) var catalogFetches = 0

    func send(_ request: URLRequest) async throws -> HTTPReply {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/catalog.json") {
            catalogFetches += 1
            return HTTPReply(data: try FixtureLoader.data(.catalog), statusCode: 200, url: request.url)
        }
        if path.hasSuffix("/res/63459413.json") {
            return HTTPReply(data: try FixtureLoader.data(.thread), statusCode: 200, url: request.url)
        }
        return HTTPReply(data: Data(), statusCode: 404, url: request.url)
    }
}
