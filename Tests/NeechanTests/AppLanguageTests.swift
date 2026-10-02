import Foundation
import NeechanAPI
import Testing

/// A string built in code is in the language picked in the app, whatever the
/// device is set to.
///
/// The regression: every one followed the device. On a phone set to Russian
/// with the app set to English, a new theme was offered as "Моя тема". The
/// strings asked for the app's locale, which only formats what is
/// interpolated; the translation comes from the bundle, which nothing asked.
///
/// Here rather than in a package test because only the app's build compiles
/// the string catalog into one table per language.
@Suite("Strings follow the app's language", .serialized)
struct AppLanguageTests {
    /// The interface package's strings, as the app carries them.
    private func interfaceStrings() throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: "NeechanUI_NeechanUI", withExtension: "bundle"))
        return try #require(Bundle(url: url))
    }

    @Test(
        "a string is in the language chosen in the app",
        arguments: [("en", "My theme"), ("ru", "Моя тема"), ("de", "Mein Theme")]
    )
    func chosenLanguage(language: String, expected: String) throws {
        let strings = try interfaceStrings()
        AppLocale.set(Locale(identifier: language))
        defer { AppLocale.set(nil) }

        let text = String(localized: "My theme", bundle: strings.forAppLanguage(), locale: AppLocale.current)
        #expect(text == expected)
    }

    @Test("with no language chosen, the device's is used, as before")
    func followsTheDevice() throws {
        let strings = try interfaceStrings()
        AppLocale.set(nil)

        #expect(strings.forAppLanguage() === strings)
    }
}
