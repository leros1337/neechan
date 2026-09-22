import Foundation
import Testing
@testable import Neechan

/// The strings iOS itself shows, in every language the app claims to speak.
///
/// These live in `Neechan/<lang>.lproj/InfoPlist.strings` rather than in a
/// string catalog, because the system reads them out of the bundle before any
/// of our code runs. Nothing else checks them: the packages have
/// `LocalizationCatalogTests`, which covers the catalogs and not these, and a
/// missing `.lproj` is invisible — the system quietly falls back to the
/// development language, so a German reader is asked for Face ID in English
/// and nothing anywhere reports a problem. That is how `de` came to be missing
/// for as long as it was.
@Suite("Info.plist localization")
struct InfoPlistLocalizationTests {
    /// Read from the bundle rather than written out again here, so adding a
    /// language to `project.yml` is what this test follows.
    private var declaredLanguages: [String] {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] ?? []
    }

    /// Every key the app's `Info.plist` asks the system to show a person.
    private static let promptKeys = [
        "NSFaceIDUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
    ]

    @Test("the app claims the three languages it ships")
    func languagesAreDeclared() {
        #expect(Set(declaredLanguages) == ["en", "ru", "de"])
    }

    @Test("every declared language carries every system prompt")
    func everyPromptIsTranslated() throws {
        for language in declaredLanguages {
            let path = try #require(
                Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language),
                "\(language) has no InfoPlist.strings at all"
            )
            let strings = try #require(
                NSDictionary(contentsOfFile: path) as? [String: String],
                "\(language)'s InfoPlist.strings could not be read"
            )

            for key in Self.promptKeys {
                let value = strings[key]
                #expect(value?.isEmpty == false, "\(language) is missing \(key)")
            }
        }
    }

    /// A prompt left in English in a translated file is the same failure as a
    /// missing one, and harder to see. English is skipped for the obvious
    /// reason.
    @Test("a translated prompt is not just the English copied over")
    func translationsDiffer() throws {
        let english = try strings(for: "en")

        for language in declaredLanguages where language != "en" {
            let translated = try strings(for: language)
            for key in Self.promptKeys {
                #expect(
                    translated[key] != english[key],
                    "\(language)'s \(key) is still the English sentence"
                )
            }
        }
    }

    private func strings(for language: String) throws -> [String: String] {
        let path = try #require(
            Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language)
        )
        return try #require(NSDictionary(contentsOfFile: path) as? [String: String])
    }
}
