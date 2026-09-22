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
                #expect(capabilities.reporting == .api)
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
                // `.web`, not `.none`: 4chan has no report endpoint, but it
                // does have a report page, and a browser engine reaches it.
                #expect(capabilities.reporting == .web)
                #expect(capabilities.captcha == .slider)
                #expect(capabilities.markup == .fourchan)
            }
        }
    }

    /// The report action is the one thing Apple's rules for user-generated
    /// content require that the reader cannot supply for themselves, so a site
    /// that offers neither route is a site the app should not be reading.
    @Test("every imageboard can be reported to, one way or the other")
    func everySiteCanBeReported() {
        for site in Imageboard.allCases {
            #expect(SiteCapabilities.of(site).reporting != .none)
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

    /// Offered wherever the saved copy can be read back, which is now both
    /// sites. It was 2ch-only for as long as the archiver read every saved file
    /// as 2ch's shape; it reads each one the way the site that wrote it writes
    /// threads, and the saved row had recorded which site that was all along.
    ///
    /// A site added later has to answer for this: saving is not free to turn on
    /// until `SavedThreadsRepository.load` can decode what it wrote.
    @Test("saving threads is offered wherever the saved copy can be read back")
    func savingIsOnlyWhereItWorks() {
        for site in Imageboard.allCases {
            #expect(SiteCapabilities.of(site).savingThreads, "\(site) cannot save")
        }
    }
}
