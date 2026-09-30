import Foundation
import Testing
@testable import NeechanUI

/// The icons the app can wear.
@Suite("App icon choice")
struct AppIconChoiceTests {
    /// The shipped icon has no name: that is how the system says "the original".
    ///
    /// `neechan` sits in the *trailing* catalogue slot so the App Store build
    /// can drop it by naming one fewer alternate icon. Swapping these two
    /// without swapping the PNGs in `Neechan/Assets.xcassets` would put the
    /// wrong picture on the home screen, which nothing else here would catch.
    @Test("the icon the app ships with is nameless")
    func originalHasNoName() {
        #expect(AppIconChoice.original.alternateName == nil)
        #expect(AppIconChoice.peace.alternateName == "AppIcon2")
        #expect(AppIconChoice.neechan.alternateName == "AppIcon3")
    }

    @Test("what the system reports reads back as a choice")
    func namedRoundTrips() {
        #expect(AppIconChoice.named(nil) == .original)
        #expect(AppIconChoice.named("AppIcon2") == .peace)
        #expect(AppIconChoice.named("AppIcon3") == .neechan)
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

    /// The picker order is `allCases`, and the reader sees it left to right.
    @Test("the nude artwork is offered last")
    func neechanIsLast() {
        #expect(AppIconChoice.allCases == [.original, .peace, .neechan])
    }

    /// A restricted build's catalogue does not carry `AppIcon3` at all, so
    /// offering it would be a row that cannot be chosen.
    @Test("a restricted build does not offer the nude artwork")
    func restrictedDropsNeechan() {
        #expect(AppIconChoice.available(isRestrictedBuild: true) == [.original, .peace])
    }

    @Test("the unrestricted build offers all three")
    func unrestrictedBuildOffersEverything() {
        #expect(AppIconChoice.available(isRestrictedBuild: false) == AppIconChoice.allCases)
    }

    /// A reader who wore the nude icon before an update to a build without it.
    /// The picker should mark the icon the home screen falls back to, not
    /// mark nothing at all.
    @Test("an icon the build no longer carries reads as the original")
    func aDroppedIconReadsAsOriginal() {
        #expect(AppIconChoice.named("AppIcon3", isRestrictedBuild: true) == .original)
        #expect(AppIconChoice.named("AppIcon3", isRestrictedBuild: false) == .neechan)
        #expect(AppIconChoice.named("AppIcon2", isRestrictedBuild: true) == .peace)
    }
}
