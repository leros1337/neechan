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
