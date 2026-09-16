import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("HTML entities")
struct HTMLEntityTests {
    @Test("named entities decode", arguments: [
        ("&gt;", ">"), ("&lt;", "<"), ("&amp;", "&"), ("&quot;", "\""),
        ("&apos;", "'"), ("&nbsp;", "\u{00A0}"),
    ])
    func namedEntities(input: String, expected: String) {
        #expect(HTMLEntities.decode(input) == expected)
    }

    @Test("2ch escapes slashes as numeric entities")
    func numericSlash() {
        #expect(HTMLEntities.decode("https:&#47;&#47;example.com&#47;a") == "https://example.com/a")
        #expect(HTMLEntities.decode("100&#37;") == "100%")
    }

    @Test("hexadecimal references decode")
    func hexEntities() {
        #expect(HTMLEntities.decode("&#x41;&#x42;") == "AB")
    }

    @Test("an ampersand that is not an entity is left alone")
    func looseAmpersand() {
        #expect(HTMLEntities.decode("R&D &notanentity; x") == "R&D &notanentity; x")
    }

    @Test("text without entities is returned unchanged")
    func passthrough() {
        #expect(HTMLEntities.decode("обычный текст") == "обычный текст")
    }
}

@Suite("Comment parser")
struct CommentParserTests {
    private func parse(_ html: String) -> PostContent {
        CommentHTMLParser().parse(html, inThread: 100, onBoard: "b")
    }

    // MARK: Text and breaks

    @Test("plain text survives")
    func plainText() {
        #expect(parse("привет").plainText == "привет")
    }

    @Test("line breaks become break nodes, not text")
    func lineBreaks() {
        let content = parse("a<br>b<br />c")
        #expect(content.plainText == "a\nb\nc")
    }

    @Test("entities inside text are decoded")
    func entitiesInText() {
        #expect(parse("&quot;цитата&quot;").plainText == "\"цитата\"")
    }

    // MARK: Inline styles

    @Test("inline tags map to styles", arguments: [
        ("<strong>x</strong>", PostStyle.bold),
        ("<b>x</b>", PostStyle.bold),
        ("<em>x</em>", PostStyle.italic),
        ("<i>x</i>", PostStyle.italic),
        ("<u>x</u>", PostStyle.underline),
        ("<s>x</s>", PostStyle.strikethrough),
        ("<strike>x</strike>", PostStyle.strikethrough),
        ("<sup>x</sup>", PostStyle.superscript),
        ("<sub>x</sub>", PostStyle.subscript),
    ])
    func inlineStyles(html: String, expected: PostStyle) {
        let content = parse(html)
        #expect(content.plainText == "x")
        #expect(content.styles(at: 0).contains(expected))
    }

    @Test("span classes map to styles too")
    func spanClasses() {
        #expect(parse(#"<span class="u">x</span>"#).styles(at: 0).contains(.underline))
        #expect(parse(#"<span class="s">x</span>"#).styles(at: 0).contains(.strikethrough))
        #expect(parse(#"<span class="o">x</span>"#).styles(at: 0).contains(.overline))
    }

    @Test("nested styles combine")
    func nestedStyles() {
        let content = parse("<strong><em>x</em></strong>")
        let styles = content.styles(at: 0)
        #expect(styles.contains(.bold))
        #expect(styles.contains(.italic))
    }

    // MARK: Semantic spans

    @Test("unkfunc is greentext, and keeps its marker")
    func greentext() {
        let content = parse(#"<span class="unkfunc">&gt;цитата</span>"#)
        #expect(content.plainText == ">цитата")
        #expect(content.containsQuote)
    }

    @Test("spoilers are their own node so they can be tapped")
    func spoilers() {
        let content = parse(#"пред<span class="spoiler">скрыто</span>пост"#)
        #expect(content.plainText == "предскрытопост")
        #expect(content.containsSpoiler)
    }

    @Test("code blocks preserve their text")
    func codeBlocks() {
        let content = parse("<pre>let x = 1</pre>")
        #expect(content.plainText.contains("let x = 1"))
        #expect(content.containsCode)
    }

    @Test("AI-generated posts are flagged")
    func aiMarkup() {
        let content = parse(#"<div class="neuroslop">сгенерировано</div>"#)
        #expect(content.isAIGenerated)
    }

    // MARK: Links

    @Test("a reply link is parsed from its data attributes")
    func replyLink() {
        let html = #"<a href="/po/res/63459413.html#63459499" class="post-reply-link" "#
            + #"data-thread="63459413" data-num="63459499">&gt;&gt;63459499</a>"#
        let content = parse(html)
        let reference = try! #require(content.references.first)
        #expect(reference.postNum == 63459499)
        #expect(reference.threadNum == 63459413)
        #expect(content.plainText == ">>63459499")
    }

    @Test("a reply link without data attributes falls back to its href")
    func replyLinkFromHref() {
        let html = #"<a href="/b/res/111.html#222" class="post-reply-link">&gt;&gt;222</a>"#
        let reference = try! #require(parse(html).references.first)
        #expect(reference.postNum == 222)
        #expect(reference.threadNum == 111)
        #expect(reference.board == "b")
    }

    @Test("a link into the same thread is marked as such")
    func sameThreadReference() {
        let html = #"<a class="post-reply-link" data-thread="100" data-num="101">&gt;&gt;101</a>"#
        let reference = try! #require(parse(html).references.first)
        #expect(reference.isSameThread)
    }

    @Test("a link into another thread is not")
    func crossThreadReference() {
        let html = #"<a class="post-reply-link" data-thread="999" data-num="1001">&gt;&gt;1001</a>"#
        let reference = try! #require(parse(html).references.first)
        #expect(reference.isSameThread == false)
    }

    @Test("external links keep their address, with slashes unescaped")
    func externalLinks() {
        let html = #"<a href="https:&#47;&#47;example.com&#47;a?b=1&amp;c=2" target="_blank">тут</a>"#
        let content = parse(html)
        #expect(content.externalLinks == ["https://example.com/a?b=1&c=2"])
        #expect(content.plainText == "тут")
    }

    @Test("a link with no href degrades to plain text")
    func anchorWithoutHref() {
        #expect(parse("<a>текст</a>").plainText == "текст")
    }

    // MARK: Leniency

    @Test("an unclosed tag does not swallow the rest of the comment")
    func unclosedTag() {
        let content = parse("<strong>жирный<br>дальше")
        #expect(content.plainText == "жирный\nдальше")
    }

    @Test("a stray closing tag is ignored")
    func strayClosingTag() {
        #expect(parse("текст</strong>ещё").plainText == "текстещё")
    }

    @Test("an unknown tag is dropped but its content kept")
    func unknownTag() {
        #expect(parse("<marquee>бегущая</marquee>").plainText == "бегущая")
    }

    @Test("a bare angle bracket is treated as text")
    func bareAngleBracket() {
        #expect(parse("2 < 3 и 5 > 4").plainText.contains("<"))
    }

    @Test("mismatched nesting still closes cleanly")
    func mismatchedNesting() {
        let content = parse("<strong><em>x</strong></em>")
        #expect(content.plainText == "x")
    }

    @Test("script and style contents are dropped entirely")
    func scriptIsDropped() {
        let content = parse("до<script>alert(1)</script>после")
        #expect(content.plainText == "допосле")
    }

    @Test("an empty comment parses to empty content")
    func emptyComment() {
        #expect(parse("").plainText.isEmpty)
        #expect(parse("").isEmpty)
    }

    // MARK: Real corpus

    @Test("every recorded comment parses without throwing or losing its text")
    func corpusParses() throws {
        let parser = CommentHTMLParser()
        for sample in try FixtureLoader.commentSamples() {
            let content = parser.parse(sample.comment, inThread: 0, onBoard: "b")
            #expect(
                content.plainText.contains("<") == false || sample.comment.contains("&lt;"),
                "post \(sample.num) leaked markup into its text"
            )
        }
    }

    @Test("the corpus exercises reply links, greentext and spoilers")
    func corpusIsRepresentative() throws {
        let parser = CommentHTMLParser()
        var references = 0
        var quotes = 0
        var spoilers = 0
        for sample in try FixtureLoader.commentSamples() {
            let content = parser.parse(sample.comment, inThread: 0, onBoard: "b")
            references += content.references.count
            quotes += content.containsQuote ? 1 : 0
            spoilers += content.containsSpoiler ? 1 : 0
        }
        #expect(references > 50)
        #expect(quotes > 5)
        #expect(spoilers > 3)
    }

    @Test("parsing arbitrary bytes never throws", arguments: [
        "<<<>>>", "<a href=", "<span class=", "&#;", "&#xZZ;", "<br", "</>", "<!-- c -->",
        "<a href=\"x\"", String(repeating: "<b>", count: 500),
    ])
    func neverThrowsOnMalformedHTML(_ html: String) {
        _ = parse(html)
    }
}
