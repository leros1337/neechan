import Foundation
import NeechanAPI
import Testing
@testable import NeechanCore

/// The board set the App Store build lists.
@Suite("App Store boards")
struct AppStoreBoardsTests {
    /// The invariant the table is easiest to break: a board named here but also
    /// named by `MatureBoards` would be listed in the directory and then refuse
    /// to open, which reads as a broken app rather than as a gate.
    ///
    /// It is how /i/ and /ic/ left the 4chan list and /to/, /aa/, /td/ and
    /// /izd/ the 2ch one — every board a 2ch reader made is adult-gated
    /// wholesale, and the art boards there are all reader-made.
    @Test("nothing listed is also gated for adults", arguments: [Imageboard.dvach, .fourchan])
    func nothingListedIsAlsoMature(site: Imageboard) {
        let overlap = AppStoreBoards.codes(on: site)
            .filter { MatureBoards.contains($0, on: site) }
            .sorted()

        #expect(overlap.isEmpty, "listed but unopenable on \(site): \(overlap)")
    }

    /// The same invariant as above, asked the way the app asks it.
    ///
    /// `nothingListedIsAlsoMature` compares two tables; this goes through
    /// ``ContentPolicy`` with the App Store build's own starting policy — the
    /// directory narrowed, the age gate shut — which is what the router and the
    /// board rows actually call. So it catches a bad addition to either table
    /// *and* a change to how the policy composes them.
    @Test("every listed board opens on the build that lists it", arguments: [Imageboard.dvach, .fourchan])
    func everyListedBoardOpens(site: Imageboard) {
        let policy = ContentPolicy(allowsMatureBoards: false, listsEveryBoard: false)
        let refused = AppStoreBoards.codes(on: site)
            .filter { !policy.allowsOpening(code: $0, on: site) }
            .sorted()

        #expect(refused.isEmpty, "listed but refused on \(site): \(refused)")
    }

    /// The section as it was added, and the two boards it stops short of.
    ///
    /// `/izd/` and `/wp/` are left out for different reasons, and the
    /// difference is worth keeping: `/wp/` is merely unlisted and could be
    /// added by anyone who wants it, while `/izd/` is *gated* — 2ch files it
    /// under Пользовательские, and every reader-made board is adult-gated, so
    /// listing it would show a board that then refused to open. This is here so
    /// that adding either has to be deliberate.
    @Test("the Творчество section is listed, without the two it leaves out")
    func creativitySectionIsListed() {
        for code in ["de", "di", "diy", "mus", "p", "wrk"] {
            #expect(AppStoreBoards.contains(code, on: .dvach), "/\(code)/ is not listed")
        }

        #expect(!AppStoreBoards.contains("wp", on: .dvach), "/wp/ was listed")
        #expect(!AppStoreBoards.contains("izd", on: .dvach), "/izd/ was listed, and it is gated")
        #expect(MatureBoards.contains("izd", on: .dvach), "/izd/ stopped being gated")
    }

    /// Boards taken back out of the App Store set after it shipped: /fd/
    /// Фэндомы and /pa/ Живопись on 2ch, /cm/ Cute/Male on 4chan. None of them
    /// is gated, so they still open when typed; they are only not listed.
    @Test("the boards taken out stay out")
    func removedBoardsAreNotListed() {
        for code in ["fd", "pa"] {
            #expect(!AppStoreBoards.contains(code, on: .dvach), "/\(code)/ was listed")
        }
        #expect(!AppStoreBoards.contains("cm", on: .fourchan), "/cm/ was listed")
    }

    /// The codes genuinely collide between the two sites — `/m/` is Mecha on
    /// 4chan and a reader-made board on 2ch — so a table read on the wrong
    /// site gives the wrong answer.
    @Test("a code is judged on its own site")
    func codesAreSiteSpecific() {
        #expect(AppStoreBoards.contains("co", on: .fourchan))
        #expect(!AppStoreBoards.contains("co", on: .dvach))
        #expect(AppStoreBoards.contains("ma", on: .dvach))
        #expect(!AppStoreBoards.contains("ma", on: .fourchan))
    }

    /// Readers type `/A/`; a `ThreadKey` carries a bare `a`; neither has been
    /// through `BoardCode.normalized`.
    @Test("however the code was written, it is the same board")
    func codesAreNormalised() {
        for written in ["a", "A", "/a/", " /A/ "] {
            #expect(AppStoreBoards.contains(written, on: .dvach), "\(written) was not recognised")
        }
        #expect(!AppStoreBoards.contains("", on: .dvach))
    }

    @Test("a board nobody listed is not listed")
    func unlistedIsUnlisted() {
        #expect(!AppStoreBoards.contains("vg", on: .dvach))
        #expect(!AppStoreBoards.contains("g", on: .fourchan))
    }

    /// Anime is the whole point of the set, on both sites.
    @Test("anime is listed on both sites")
    func animeIsListed() {
        #expect(AppStoreBoards.contains("a", on: .dvach))
        #expect(AppStoreBoards.contains("a", on: .fourchan))
    }
}
