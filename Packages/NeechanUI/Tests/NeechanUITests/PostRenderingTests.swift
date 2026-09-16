import Foundation
import NeechanAPI
import NeechanCore
import SwiftUI
import Testing
@testable import NeechanUI

@Suite("Neechan URL scheme")
struct NeechanURLTests {
    @Test("a reply reference round-trips through a link")
    func postRoundTrip() throws {
        let reference = PostReference(board: "b", threadNum: 100, postNum: 101, isSameThread: true)
        let url = try #require(NeechanURL.post(reference))
        #expect(NeechanURL.action(for: url) == .post(board: "b", threadNum: 100, postNum: 101))
    }

    @Test("a reference with no thread still resolves to the post")
    func postWithoutThread() throws {
        let reference = PostReference(board: "b", threadNum: nil, postNum: 5, isSameThread: true)
        let url = try #require(NeechanURL.post(reference))
        #expect(NeechanURL.action(for: url) == .post(board: "b", threadNum: nil, postNum: 5))
    }

    @Test("a spoiler toggle round-trips")
    func spoilerRoundTrip() throws {
        let url = try #require(NeechanURL.spoilerToggle(postNum: 42))
        #expect(NeechanURL.action(for: url) == .toggleSpoilers(postNum: 42))
    }

    @Test("a web link is reported as external")
    func externalLink() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(NeechanURL.action(for: url) == .external(url))
    }

    @Test("a malformed link in our own scheme degrades to external")
    func malformedInternalLink() throws {
        let url = try #require(URL(string: "neechan://post?board=b"))
        #expect(NeechanURL.action(for: url) == .external(url))
    }
}

@Suite("Post text renderer")
struct PostTextRendererTests {
    private let parser = CommentHTMLParser()
    private let renderer = PostTextRenderer()

    private func render(_ html: String, revealSpoilers: Bool = false) -> AttributedString {
        let content = parser.parse(html, inThread: 100, onBoard: "b")
        return renderer.render(
            content,
            options: .init(postNum: 101, revealSpoilers: revealSpoilers)
        )
    }

    @Test("plain text renders unchanged")
    func plainText() {
        #expect(String(render("привет").characters) == "привет")
    }

    @Test("line breaks become newlines")
    func lineBreaks() {
        #expect(String(render("a<br>b").characters) == "a\nb")
    }

    @Test("bold is marked as emphasis, not as literal asterisks")
    func boldEmphasis() {
        let rendered = render("<strong>жирный</strong>")
        let intents = rendered.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains { $0.contains(.stronglyEmphasized) })
    }

    @Test("greentext is coloured")
    func greentextColour() {
        let rendered = render(#"<span class="unkfunc">&gt;цитата</span>"#)
        #expect(rendered.runs.contains { $0.foregroundColor == .postQuote })
    }

    @Test("a reply reference becomes a tappable link in our scheme")
    func replyLinkIsTappable() throws {
        let rendered = render(
            #"<a class="post-reply-link" data-thread="100" data-num="99">&gt;&gt;99</a>"#
        )
        let link = try #require(rendered.runs.compactMap(\.link).first)
        #expect(NeechanURL.action(for: link) == .post(board: "b", threadNum: 100, postNum: 99))
    }

    @Test("an external link keeps its own address")
    func externalLinkIsPreserved() throws {
        let rendered = render(#"<a href="https://example.com/x">тут</a>"#)
        let link = try #require(rendered.runs.compactMap(\.link).first)
        #expect(link.absoluteString == "https://example.com/x")
    }

    @Test("a hidden spoiler is blocked out and tappable")
    func hiddenSpoiler() throws {
        let rendered = render(#"<span class="spoiler">секрет</span>"#)
        // The text is still present so revealing it does not reflow the post.
        #expect(String(rendered.characters) == "секрет")
        let run = try #require(rendered.runs.first { $0.backgroundColor == .defaultSpoilerHidden })
        #expect(run.foregroundColor == .defaultSpoilerHidden)
        #expect(run.link != nil)
    }

    @Test("a revealed spoiler is readable and no longer a toggle target")
    func revealedSpoiler() {
        let rendered = render(#"<span class="spoiler">секрет</span>"#, revealSpoilers: true)
        #expect(rendered.runs.allSatisfy { $0.foregroundColor != .defaultSpoilerHidden })
        #expect(rendered.runs.contains { $0.backgroundColor == .defaultSpoilerRevealed })
    }

    @Test("nested styles both apply")
    func nestedStyles() {
        let rendered = render("<strong><u>оба</u></strong>")
        #expect(rendered.runs.contains { $0.underlineStyle != nil })
        #expect(
            rendered.runs.contains {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        )
    }

    @Test("an empty body renders to nothing")
    func emptyBody() {
        #expect(render("").characters.isEmpty)
    }
}

/// The colours a post uses come from the scheme the reader picked, so choosing
/// a theme changes more than the accent on a button.
@Suite("Themed post colours")
struct ThemedRenderingTests {
    private let parser = CommentHTMLParser()
    private let renderer = PostTextRenderer()

    private func render(
        _ html: String,
        palette: PostTextRenderer.Palette,
        revealSpoilers: Bool = false
    ) -> AttributedString {
        renderer.render(
            parser.parse(html, inThread: 100, onBoard: "b"),
            options: .init(postNum: 101, revealSpoilers: revealSpoilers, palette: palette)
        )
    }

    @Test("greentext takes the scheme's quote colour")
    func quoteFollowsTheScheme() throws {
        let scheme = try #require(NeechanTheme.builtIn(id: "neechan.crimson"))
        let palette = PostTextRenderer.Palette(theme: scheme)
        let rendered = render(#"<span class="unkfunc">&gt;цитата</span>"#, palette: palette)

        #expect(rendered.runs.contains { $0.foregroundColor == Color(scheme.quote) })
    }

    @Test("two schemes do not render a post the same way")
    func schemesDiffer() throws {
        let first = try #require(NeechanTheme.builtIn(id: "neechan.forest"))
        let second = try #require(NeechanTheme.builtIn(id: "neechan.crimson"))
        let html = #"<span class="unkfunc">&gt;цитата</span>"#

        let a = render(html, palette: .init(theme: first)).runs.compactMap(\.foregroundColor)
        let b = render(html, palette: .init(theme: second)).runs.compactMap(\.foregroundColor)
        #expect(a != b)
    }

    @Test("a link takes the scheme's link colour")
    func linksFollowTheScheme() throws {
        let scheme = try #require(NeechanTheme.builtIn(id: "neechan.amethyst"))
        let rendered = render(
            #"<a href="https://example.org">там</a>"#,
            palette: .init(theme: scheme)
        )

        #expect(rendered.runs.contains { $0.foregroundColor == Color(scheme.link) })
    }

    @Test("the default palette is the shipped scheme, so a plain render is unchanged")
    func defaultPalette() {
        #expect(PostTextRenderer.Palette() == PostTextRenderer.Palette(theme: .builtIn))
    }
}
