import Foundation
import Testing
@testable import NeechanAPI

/// The bits of HTML 4chan's captcha puts in front of the reader.
///
/// The site's own script sets them as `innerHTML`, so a prompt can carry the
/// picture it asks about and a wait can carry a link. Shown as text, both came
/// out as markup: a prompt that was a wall of base64, and a link nobody could
/// follow.
@Suite("4chan captcha markup")
struct FourchanCaptchaMarkupTests {
    private func plain(_ markup: FourchanCaptchaMarkup) -> String {
        String(markup.text.characters)
    }

    /// The shape a live prompt arrived in.
    @Test("a prompt's words and its picture are told apart")
    func promptWithPicture() {
        let markup = FourchanCaptchaMarkup(
            html: #"Use the scroll bar below to find the image that contains the object on the right, then click Next.<img src="data:image/png;base64,iVBORw0KGgo+/=" alt="">"#
        )
        #expect(
            plain(markup)
                == "Use the scroll bar below to find the image that contains the object on the right, then click Next."
        )
        #expect(markup.images == ["iVBORw0KGgo+/="])
    }

    @Test("a picture before the words is found as well")
    func pictureFirst() {
        let markup = FourchanCaptchaMarkup(html: #"<img src='data:image/png;base64,AAAA'><br>Find it"#)
        #expect(markup.images == ["AAAA"])
        #expect(plain(markup) == "Find it")
    }

    /// The live wait message, word for word.
    @Test("a link keeps its words and becomes something to follow")
    func link() throws {
        let markup = FourchanCaptchaMarkup(
            html: #"Please wait a while before making a post or verify your email <a target="_blank" href="https://sys.4chan.org/signin">here</a>."#
        )
        #expect(plain(markup) == "Please wait a while before making a post or verify your email here.")

        let linked = markup.text.runs.compactMap { run -> (String, URL)? in
            guard let link = run.link else { return nil }
            return (String(markup.text[run.range].characters), link)
        }
        #expect(linked.count == 1)
        #expect(linked.first?.0 == "here")
        #expect(linked.first?.1 == URL(string: "https://sys.4chan.org/signin"))
    }

    @Test("a line break is a line break, and entities are characters")
    func breaksAndEntities() {
        let markup = FourchanCaptchaMarkup(html: "One &amp; two<br/>three &quot;four&quot;<BR>five")
        #expect(plain(markup) == "One & two\nthree \"four\"\nfive")
    }

    @Test("other tags are dropped and their words kept")
    func otherTags() {
        let markup = FourchanCaptchaMarkup(html: "<div><b>Bold</b> and <span class=\"x\">plain</span></div>")
        #expect(plain(markup) == "Bold and plain")
        #expect(markup.images.isEmpty)
    }

    @Test("plain words pass through untouched")
    func plainText() {
        #expect(plain(FourchanCaptchaMarkup(html: "You have to wait a while before doing this again.")) == "You have to wait a while before doing this again.")
    }

    /// Only links a reader could follow: anything else stays words.
    @Test("a link to nowhere useful is left as words")
    func unsafeLink() {
        let markup = FourchanCaptchaMarkup(html: #"<a href="javascript:alert(1)">this</a>"#)
        #expect(plain(markup) == "this")
        #expect(markup.text.runs.allSatisfy { $0.link == nil })
    }

    @Test("a picture from anywhere but the reply itself is not fetched")
    func remotePicture() {
        let markup = FourchanCaptchaMarkup(html: #"<img src="https://example.com/a.png">words"#)
        #expect(markup.images.isEmpty)
        #expect(plain(markup) == "words")
    }

    @Test("a step's prompt is read as markup when it arrives")
    func stepPrompt() throws {
        let captcha = try JSONDecoder().decode(
            FourchanCaptcha.self,
            from: Data(#"{"challenge":"c","tasks":[{"str":"Find it<img src=\"data:image/png;base64,QQ==\">","items":["A"]}]}"#.utf8)
        )
        let prompt = try #require(captcha.steps.first?.prompt)
        #expect(plain(prompt) == "Find it")
        #expect(prompt.images == ["QQ=="])
    }
}
