import Foundation
import Testing
@testable import NeechanUI

/// Where the rows in About lead.
@Suite("About links")
struct AboutLinksTests {
    /// The site's front page picks a language from the browser's, which is the
    /// device's. The app's own language can differ, so the app names it.
    @Test("the site opens in the app's language", arguments: [
        ("ru", "https://neechan.pro/ru/", "https://neechan.pro/ru/privacy"),
        ("de_DE", "https://neechan.pro/de/", "https://neechan.pro/de/privacy"),
        ("en_GB", "https://neechan.pro/en/", "https://neechan.pro/en/privacy"),
    ])
    func siteInAppLanguage(identifier: String, website: String, privacy: String) {
        let links = AboutLinks(locale: Locale(identifier: identifier))
        #expect(links.website.absoluteString == website)
        #expect(links.privacyPolicy.absoluteString == privacy)
    }

    /// The site has pages in three languages and no others.
    @Test("a language the site does not have falls back to English")
    func unknownLanguageFallsBack() {
        let links = AboutLinks(locale: Locale(identifier: "ja_JP"))
        #expect(links.website.absoluteString == "https://neechan.pro/en/")
        #expect(links.privacyPolicy.absoluteString == "https://neechan.pro/en/privacy")
    }

    @Test("source and contact do not depend on the language")
    func fixedLinks() {
        let links = AboutLinks(locale: Locale(identifier: "ru"))
        #expect(links.sourceCode.absoluteString == "https://github.com/leros1337/neechan")
        #expect(links.contact.absoluteString == "mailto:neechan-dev@proton.me")
    }
}
