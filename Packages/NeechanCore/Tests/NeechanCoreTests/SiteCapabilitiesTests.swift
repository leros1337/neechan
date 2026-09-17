import Foundation
import NeechanAPI
import Testing
@testable import NeechanCore

@Suite("Site capabilities")
struct SiteCapabilitiesTests {
    /// Adding a third imageboard should fail a test rather than quietly
    /// inheriting whatever 2ch happens to answer.
    @Test("every imageboard has an explicit answer for every capability")
    func everySiteIsAccountedFor() {
        for site in Imageboard.allCases {
            let capabilities = SiteCapabilities.of(site)
            switch site {
            case .dvach:
                #expect(capabilities.posting)
                #expect(capabilities.incrementalThreadRefresh)
                #expect(capabilities.cheapThreadPoll)
                #expect(capabilities.serverSearch)
                #expect(capabilities.captcha == .emoji)
                #expect(capabilities.markup == .wakaba)
            case .fourchan:
                // On, though the posting host's own gate refuses a cookie
                // replayed from a web view and so nothing the app sends itself
                // gets through today. See `SiteCapabilities.fourchan`.
                #expect(capabilities.posting)
                #expect(capabilities.incrementalThreadRefresh == false)
                #expect(capabilities.cheapThreadPoll == false)
                #expect(capabilities.boardWidePoll)
                #expect(capabilities.serverSearch == false)
                #expect(capabilities.voting == false)
                #expect(capabilities.passcode == false)
                #expect(capabilities.userBoards == false)
                #expect(capabilities.captcha == .slider)
                #expect(capabilities.markup == .fourchan)
            }
        }
    }

    /// Either a site can be polled a thread at a time or a board at a time.
    /// Neither would leave the watcher with nothing to do.
    @Test("every imageboard offers the watcher some way to poll")
    func everySiteCanBeWatched() {
        for site in Imageboard.allCases {
            let capabilities = SiteCapabilities.of(site)
            #expect(capabilities.cheapThreadPoll || capabilities.boardWidePoll)
        }
    }

    /// The saved-thread archiver keeps the server's own bytes and reads them
    /// back as 2ch's shape, so it must not be offered anywhere else until it
    /// records which site wrote them.
    @Test("saving threads is only offered where the saved copy can be read back")
    func savingIsOnlyWhereItWorks() {
        #expect(SiteCapabilities.of(.dvach).savingThreads)
        #expect(SiteCapabilities.of(.fourchan).savingThreads == false)
    }
}
