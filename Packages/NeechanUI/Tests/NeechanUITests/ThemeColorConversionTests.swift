import NeechanCore
import SwiftUI
import Testing
@testable import NeechanUI

/// A colour picked in the palette comes back as the colour that was picked.
///
/// The picker hands over a SwiftUI `Color`, and a theme keeps plain numbers;
/// the two have to agree, or a theme saved from the palette would come out a
/// shade off from what the reader chose.
@Suite("Colours from the palette")
struct ThemeColorConversionTests {
    @Test(
        "a theme colour survives being shown and picked again",
        arguments: [
            ThemeColor(red: 0.85, green: 0.58, blue: 0.13),
            ThemeColor(red: 0, green: 0, blue: 0),
            ThemeColor(red: 1, green: 1, blue: 1),
            ThemeColor(red: 0.2, green: 0.6, blue: 0.3, opacity: 0.5),
        ]
    )
    func roundTrip(colour: ThemeColor) {
        let back = ThemeColor(Color(colour))
        let tolerance = 1.0 / 255

        #expect(abs(back.red - colour.red) <= tolerance)
        #expect(abs(back.green - colour.green) <= tolerance)
        #expect(abs(back.blue - colour.blue) <= tolerance)
        #expect(abs(back.opacity - colour.opacity) <= tolerance)
    }

    /// A wide-gamut pick can fall outside sRGB; a theme colour cannot.
    @Test("a colour outside what a theme holds is kept within it")
    func clamped() {
        let back = ThemeColor(Color(.displayP3, red: 1, green: 0, blue: 0))

        for component in [back.red, back.green, back.blue, back.opacity] {
            #expect((0...1).contains(component))
        }
    }
}
