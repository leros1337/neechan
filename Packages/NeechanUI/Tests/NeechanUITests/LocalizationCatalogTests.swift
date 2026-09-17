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

    /// Where the packages live, found by walking up from this file rather than
    /// by a path baked into the test.
    private static var packages: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // NeechanUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // NeechanUI
            .deletingLastPathComponent()  // Packages
    }

    /// Every catalog in the project, not only this package's.
    ///
    /// Four packages carry strings, and three of them carry only a handful —
    /// which is exactly why they are the ones a new language gets forgotten in.
    /// One test over all of them is cheaper than three tests that have to be
    /// remembered separately.
    static func catalogURLs() throws -> [URL] {
        let found = FileManager.default.enumerator(
            at: packages, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "Localizable.xcstrings" }
            // A checkout of a dependency is not ours to translate.
            .filter { !$0.path.contains("/.build/") }
            ?? []
        return found.sorted { $0.path < $1.path }
    }

    private func loadCatalog(at url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func loadCatalog() throws -> Catalog {
        try loadCatalog(
            at: Self.packages.appending(path: "NeechanUI/Sources/NeechanUI/Resources/Localizable.xcstrings")
        )
    }

    /// Every language the app claims to speak, as `CFBundleLocalizations` lists
    /// them. A string missing one of these still builds and still runs; it just
    /// shows English to somebody who asked for something else.
    static let languages: Set<String> = ["en", "ru", "de"]

    @Test("every string is written in every language the app offers")
    func everyStringIsTranslated() throws {
        var incomplete: [String] = []

        for url in try Self.catalogURLs() {
            let package = url.pathComponents.dropLast(4).last ?? "?"
            for (key, entry) in try loadCatalog(at: url).strings {
                let languages = Set(entry.localizations?.keys ?? [:].keys)
                let absent = Self.languages.subtracting(languages)
                if !absent.isEmpty {
                    incomplete.append("\(package): \(key) [\(absent.sorted().joined(separator: ", "))]")
                }
            }
        }

        #expect(incomplete.isEmpty, "not translated:\n\(incomplete.sorted().joined(separator: "\n"))")
    }

    @Test("every package's catalog is found, not just this one's")
    func everyCatalogIsChecked() throws {
        let urls = try Self.catalogURLs()
        let packages = Set(urls.map { $0.pathComponents.dropLast(4).last ?? "?" })
        #expect(packages.isSuperset(of: ["NeechanAPI", "NeechanCore", "NeechanMedia", "NeechanUI"]),
                "found only \(packages.sorted())")
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
