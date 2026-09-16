import Foundation
import Testing

/// Guards the string catalog, which is easy to add to and easy to forget.
///
/// The catalog is read from the source tree rather than the built bundle: a
/// missing Russian translation still builds and still runs, and only shows up
/// as English text in front of a Russian reader.
@Suite("String catalog")
struct LocalizationCatalogTests {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let localizations: [String: JSONValue]?
        }
        let strings: [String: Entry]
    }

    /// Enough of a JSON value to tell "this language is present" without
    /// modelling every shape a localization can take.
    private struct JSONValue: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private func loadCatalog() throws -> Catalog {
        // The test file sits beside the sources, so the catalog is found by
        // walking up from it rather than by a path baked into the test.
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/NeechanUI/Resources/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: sources))
    }

    @Test("every string is written in both languages")
    func everyStringHasBothLanguages() throws {
        let catalog = try loadCatalog()

        let incomplete = catalog.strings
            .filter { _, entry in
                let languages = Set(entry.localizations?.keys ?? [:].keys)
                return !languages.isSuperset(of: ["en", "ru"])
            }
            .keys
            .sorted()

        #expect(incomplete.isEmpty, "not translated: \(incomplete.joined(separator: ", "))")
    }

    @Test("the catalog is not empty, which would mean it failed to load")
    func catalogLoads() throws {
        #expect(try loadCatalog().strings.count > 100)
    }
}

/// Guards the call sites, which the catalog test cannot see.
///
/// Reading the catalog answers "is every entry translated?". It cannot answer
/// "does the app ask for the entry, and ask the right bundle?" — and both of
/// those failed at once: the Settings rows were translated in the catalog and
/// still drew in English, while eight strings were missing from it entirely
/// because nothing ever filed them there.
@Suite("Localized call sites")
struct LocalizedCallSiteTests {
    /// Every Swift file in the packages, with its path.
    private func sources() throws -> [(path: String, text: String)] {
        let packages = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let files = try #require(
            FileManager.default.enumerator(at: packages, includingPropertiesForKeys: nil)
        )
        var result: [(String, String)] = []
        for case let url as URL in files {
            guard url.pathExtension == "swift",
                  url.path.contains("/Sources/"),
                  !url.path.contains("/.build/")
            else {
                continue
            }
            result.append((url.path, (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return result
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// `Text("…")` without a bundle looks in the app bundle, which holds no
    /// strings at all, so it draws the key: the English text.
    @Test("every literal Text names the module bundle")
    func literalTextNamesItsBundle() throws {
        var offenders: [String] = []
        for source in try sources() {
            for call in matches(#"Text\(\s*"(?:[^"\\]|\\.)*".*?\)"#, in: source.text)
            where !call.contains("bundle:") && !call.contains("verbatim:") {
                offenders.append("\(source.path.split(separator: "/").last ?? ""): \(call.prefix(60))")
            }
        }
        #expect(offenders.isEmpty, "not localizable: \(offenders.joined(separator: " | "))")
    }

    /// `LocalizedStringResource` resolves against the app bundle and the
    /// device's locale, and honours neither the module's catalog nor the
    /// language the reader picked. `LocalizedStringKey` does both.
    @Test("no view renders a LocalizedStringResource")
    func noLocalizedStringResource() throws {
        let offenders = try sources()
            .filter { $0.text.contains("LocalizedStringResource") }
            .map { $0.path.split(separator: "/").last.map(String.init) ?? "" }

        #expect(offenders.isEmpty, "use LocalizedStringKey instead, in: \(offenders)")
    }

    /// A string built in code follows the device's language unless told which
    /// one to use, so the in-app language switch would pass it by.
    @Test("every String(localized:) names the chosen locale")
    func localizedStringsFollowTheChosenLanguage() throws {
        var offenders: [String] = []
        for source in try sources() where !source.path.hasSuffix("AppLocale.swift") {
            for call in matches(#"String\(localized:.*?\)"#, in: source.text)
            where !call.contains("locale:") || !call.contains("bundle:") {
                offenders.append("\(source.path.split(separator: "/").last ?? ""): \(call.prefix(60))")
            }
        }
        #expect(offenders.isEmpty, "not following the app's language: \(offenders.joined(separator: " | "))")
    }
}
