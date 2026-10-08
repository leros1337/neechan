import Foundation
import Testing
@testable import NeechanAPI

@Suite("Post content")
struct PostContentTests {
    private func parse(_ html: String) -> PostContent {
        CommentHTMLParser().parse(html, inThread: 100, onBoard: "b")
    }

    @Test("the plain text is fixed at init and matches a walk of the nodes")
    func plainTextMatchesTheNodes() {
        let content = parse("a <b>bold</b> and <span class=\"unkfunc\">&gt;quoted</span>")
        #expect(content.plainText == "a bold and >quoted")
        // Rebuilding from the same nodes must produce the same text, which is
        // what makes storing it safe.
        #expect(PostContent(nodes: content.nodes).plainText == content.plainText)
    }

    @Test("emptiness is decided once and ignores surrounding space")
    func emptiness() {
        #expect(PostContent.empty.isEmpty)
        #expect(parse("   <br>  ").isEmpty)
        #expect(!parse("x").isEmpty)
    }

    @Test("references are collected once, in the order they appear")
    func references() {
        let content = parse(
            "<a href=\"/b/res/100.html#101\" class=\"post-reply-link\">&gt;&gt;101</a> "
                + "<a href=\"/b/res/100.html#102\" class=\"post-reply-link\">&gt;&gt;102</a>"
        )
        #expect(content.references.map(\.postNum) == [101, 102])
        #expect(PostContent(nodes: content.nodes).references.map(\.postNum) == [101, 102])
    }

    @Test("line breaks are counted from the text, so literal newlines count too")
    func lineBreaks() {
        #expect(parse("a<br>b").lineBreakCount == 1)
        #expect(parse("a<br>b<br>c").lineBreakCount == 2)
        #expect(PostContent.empty.lineBreakCount == 0)
        // A text node can carry its own newline; counting `.lineBreak` nodes
        // alone would miss it.
        #expect(PostContent(nodes: [.text("a\nb")]).lineBreakCount == 1)
    }

    @Test("two contents with the same nodes are equal and hash alike")
    func equality() {
        let first = parse("a <b>bold</b>")
        let second = PostContent(nodes: first.nodes)
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        #expect(first != parse("different"))
    }

    @Test("empty content has nothing derived from it")
    func empty() {
        #expect(PostContent.empty.plainText.isEmpty)
        #expect(PostContent.empty.references.isEmpty)
        #expect(PostContent.empty.isEmpty)
    }

    // MARK: Translating

    /// The words, in reading order, and nothing a translator would mangle: a
    /// `>>N` is a number, a link is an address, code is code.
    @Test("only the words are offered for translation")
    func translatableTexts() {
        let content = parse(
            "Hello <b>bold world</b> "
                + "<a href=\"/b/res/100.html#101\" class=\"post-reply-link\">&gt;&gt;101</a> "
                + "<a href=\"https://example.com\">https://example.com</a>"
                + "<br><span class=\"unkfunc\">&gt;green text</span>"
                + "<br><span class=\"spoiler\">secret</span> 42 !!"
        )

        // Without the space around them or a greentext's arrow, which a
        // translator would trim or drop, and which are put back as they were.
        #expect(content.translatableTexts == ["Hello", "bold world", "green text", "secret"])
    }

    @Test("putting the words back changes nothing else")
    func replacingKeepsTheTree() {
        let content = parse(
            "Hello <b>bold world</b> "
                + "<a href=\"/b/res/100.html#101\" class=\"post-reply-link\">&gt;&gt;101</a>"
        )

        let same = content.replacingTexts(content.translatableTexts)
        #expect(same == content)

        let translated = content.replacingTexts(["Привет", "жирный мир"])
        #expect(translated.plainText == "Привет жирный мир >>101")
        #expect(parse("<span class=\"unkfunc\">&gt;green</span>").replacingTexts(["зелёный"]).plainText == ">зелёный")
        #expect(translated.references.map(\.postNum) == [101])
        // Still bold, and still a link: the markup is the post's, not the words'.
        #expect(translated.styles(at: 7).contains(.bold))
    }

    /// A translator trims what it is given, and the space between two runs of
    /// a sentence is in one of them.
    @Test("the space around each run is kept")
    func surroundingSpaceIsKept() {
        let content = PostContent(nodes: [.text("  one "), .style(.bold, children: [.text("two")])])

        let translated = content.replacingTexts(["uno", "dos"])

        #expect(translated.plainText == "  uno dos")
    }

    @Test("too few translations leave the rest as they were")
    func shortListLeavesTheRest() {
        let content = parse("one <b>two</b>")

        #expect(content.replacingTexts(["uno"]).plainText == "uno two")
    }
}
