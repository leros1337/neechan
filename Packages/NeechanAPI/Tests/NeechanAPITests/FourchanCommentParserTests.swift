import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("4chan comment parser")
struct FourchanCommentParserTests {
    private let parser = CommentHTMLParser(dialect: .fourchan)

    private func parse(_ html: String, inThread thread: Int = 100) -> PostContent {
        parser.parse(html, inThread: thread, onBoard: "g")
    }

    @Test("greentext is a quote, the way the reader sees it")
    func greentext() {
        let content = parse(#"<span class="quote">&gt;implying</span>"#)
        #expect(content.containsQuote)
        #expect(content.plainText == ">implying")
    }

    /// The dominant real-world form: a same-thread quote is written as nothing
    /// but an anchor.
    @Test("a bare anchor is a quote into the thread being read")
    func sameThreadQuote() throws {
        let content = parse(##"<a href="#p109832072" class="quotelink">&gt;&gt;109832072</a>"##)
        let reference = try #require(content.references.first)
        #expect(reference.postNum == 109832072)
        #expect(reference.threadNum == nil)
        #expect(reference.isSameThread)
        #expect(reference.board == "g")
    }

    @Test("a quote naming another thread is not treated as a local one")
    func crossThreadQuote() throws {
        let content = parse(
            #"<a href="/g/thread/109832072#p109832099" class="quotelink">&gt;&gt;109832099</a>"#,
            inThread: 999
        )
        let reference = try #require(content.references.first)
        #expect(reference.board == "g")
        #expect(reference.threadNum == 109832072)
        #expect(reference.postNum == 109832099)
        #expect(reference.isSameThread == false)
    }

    @Test("a cross-board link is a link, not a quote, and it can be opened")
    func crossBoardLink() {
        let content = parse(
            #"<a href="//boards.4chan.org/wsr/" class="quotelink">&gt;&gt;&gt;/wsr/</a>"#
        )
        #expect(content.references.isEmpty)
        // Scheme-relative as sent, which nothing can open; fixed on the way in.
        #expect(content.externalLinks == ["https://boards.4chan.org/wsr/"])
    }

    /// The one tag that genuinely changes meaning between the two sites.
    @Test("s is a spoiler here and a strikethrough on 2ch")
    func strikeIsASpoiler() {
        #expect(parse("<s>secret</s>").containsSpoiler)

        let wakaba = CommentHTMLParser(dialect: .wakaba)
            .parse("<s>struck</s>", inThread: 1, onBoard: "b")
        #expect(wakaba.containsSpoiler == false)
        #expect(wakaba.styles(at: 0).contains(.strikethrough))
    }

    @Test("a code block is recognised through the class the site gives it")
    func codeBlock() {
        #expect(parse(#"<pre class="prettyprint">let x = 1</pre>"#).containsCode)
    }

    /// The site breaks long URLs with `<wbr>`. It has to vanish without taking
    /// the text on either side with it, or every long link comes out broken.
    @Test("a word-break hint leaves no trace in the text")
    func wordBreakIsInvisible() {
        #expect(parse("http://exa<wbr>mple.com").plainText == "http://example.com")
    }

    /// A quote to a post that has since been deleted. Left as the text it is:
    /// recognising it would produce a tap that goes nowhere.
    @Test("a quote to a deleted post is text, not a broken link")
    func deadLink() {
        let content = parse(#"<span class="deadlink">&gt;&gt;290611735</span>"#)
        #expect(content.plainText == ">>290611735")
        #expect(content.references.isEmpty)
    }

    @Test("line breaks survive")
    func lineBreaks() {
        #expect(parse("one<br>two").lineBreakCount == 1)
    }

    @Test("a real thread's bodies all parse, with no markup left showing")
    func corpusParses() throws {
        let response = try FourchanMapping.thread(
            from: try FixtureLoader.data(.fourchanThread),
            board: Board(id: "g"),
            endpoints: SiteEndpoints(SiteSelection(site: .fourchan)),
            decoder: JSONDecoder()
        )
        for post in response.posts {
            let content = parser.parse(post.comment, inThread: post.threadNum, onBoard: "g")
            #expect(content.plainText.contains("<span") == false)
            #expect(content.plainText.contains("<a ") == false)
            #expect(content.plainText.contains("&gt;") == false)
        }
    }
}
