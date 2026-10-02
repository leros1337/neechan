import Foundation
import Testing
@testable import NeechanAPI

/// A string built in code is in the language the reader picked in the app.
///
/// The regression: every one was in the device's language instead. They were
/// all written `String(localized:bundle:locale:)` with the app's locale, on the
/// belief that the locale picks the translation. It does not — it only formats
/// what is interpolated — so on a phone set to Russian with the app set to
/// English, "My theme" came out as "Моя тема".
@Suite("Strings in the app's language")
struct AppLanguageBundleTests {
    /// A bundle with an English and a Russian table, as Xcode builds them.
    private func makeBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lang-\(UUID().uuidString).bundle")
        for (language, value) in [("en", "My theme"), ("ru", "Моя тема")] {
            let folder = root.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("\"My theme\" = \"\(value)\";".utf8)
                .write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        return try #require(Bundle(url: root))
    }

    @Test("the chosen language's table is the one read", arguments: [("en", "My theme"), ("ru", "Моя тема")])
    func chosenLanguage(language: String, expected: String) throws {
        let bundle = try makeBundle().localized(for: Locale(identifier: language))
        #expect(String(localized: "My theme", bundle: bundle) == expected)
    }

    @Test("a region does not stop the language being found")
    func regionalLocale() throws {
        let bundle = try makeBundle().localized(for: Locale(identifier: "ru_RU"))
        #expect(String(localized: "My theme", bundle: bundle) == "Моя тема")
    }

    /// A language the app has no table for falls back to the bundle's own
    /// choice rather than to nothing.
    @Test("a language with no table is left to the bundle")
    func missingLanguage() throws {
        let original = try makeBundle()
        #expect(original.localized(for: Locale(identifier: "ja")) === original)
        #expect(original.localized(for: nil) === original)
    }
}
