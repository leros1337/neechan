import Foundation
import Testing
@testable import NeechanUI

/// The icons the app can wear.
@Suite("App icon choice")
struct AppIconChoiceTests {
    /// The shipped icon has no name: that is how the system says "the original".
    @Test("the icon the app ships with is nameless")
    func originalHasNoName() {
        #expect(AppIconChoice.original.alternateName == nil)
        #expect(AppIconChoice.neechan.alternateName == "AppIcon2")
        #expect(AppIconChoice.peace.alternateName == "AppIcon3")
    }

    @Test("what the system reports reads back as a choice")
    func namedRoundTrips() {
        #expect(AppIconChoice.named(nil) == .original)
        #expect(AppIconChoice.named("AppIcon2") == .neechan)
        #expect(AppIconChoice.named("AppIcon3") == .peace)
    }

    /// An icon removed from the bundle, or renamed, must not leave the settings
    /// screen ticking something that is not there.
    @Test("a name nobody recognises falls back to the shipped icon")
    func unknownNameFallsBack() {
        #expect(AppIconChoice.named("AppIcon9000") == .original)
    }

    /// The picker draws these, and a renamed file would show as a blank row.
    @Test("every icon has a picture that ships with the app", arguments: AppIconChoice.allCases)
    func previewsExist(choice: AppIconChoice) {
        #expect(choice.previewURL != nil, "no preview for \(choice.rawValue)")
    }

    @Test("no two icons share a name or a picture")
    func choicesAreDistinct() {
        let names = Set(AppIconChoice.allCases.map { $0.alternateName ?? "" })
        let previews = Set(AppIconChoice.allCases.map(\.previewResource))
        #expect(names.count == AppIconChoice.allCases.count)
        #expect(previews.count == AppIconChoice.allCases.count)
    }
}
