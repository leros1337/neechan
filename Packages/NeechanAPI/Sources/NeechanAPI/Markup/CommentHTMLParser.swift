import Foundation

/// Turns a post's HTML body into a `PostContent` tree.
///
/// Tags the site does not use are dropped while their text is kept, and
/// mismatched nesting is closed rather than treated as a failure, because a
/// comment that renders badly is far better than a comment that does not render.
public struct CommentHTMLParser: Sendable {
    /// Tags whose contents must never be shown.
    private static let dropped: Set<String> = ["script", "style", "head", "title"]

    /// The dialect the body is written in.
    ///
    /// The tokenizer and the node tree are shared: only which class names mean
    /// what, and how a reply link is written, actually differ. One tag genuinely
    /// changes meaning — `<s>` is struck through on 2ch and a spoiler on 4chan —
    /// so this is not merely a matter of recognising more names.
    private let dialect: MarkupDialect

    public init(dialect: MarkupDialect = .wakaba) {
        self.dialect = dialect
    }

    /// The parser for whichever markup the given imageboard writes.
    public init(site: Imageboard) {
        self.init(dialect: SiteCapabilities.of(site).markup)
    }

    /// - Parameters:
    ///   - html: the post body exactly as the server sent it.
    ///   - thread: the thread being read, so `>>N` into it can be marked local.
    ///   - board: the board being read, used when a link omits one.
    public func parse(_ html: String, inThread thread: Int, onBoard board: String) -> PostContent {
        guard !html.isEmpty else { return .empty }

        let tokens = CommentHTMLTokenizer().tokenize(html)
        var stack: [Frame] = [Frame(tag: nil, children: [])]
        var dropDepth = 0

        for token in tokens {
            switch token {
            case .text(let raw):
                guard dropDepth == 0 else { continue }
                let decoded = HTMLEntities.decode(raw)
                if !decoded.isEmpty {
                    stack[stack.count - 1].children.append(.text(decoded))
                }

            case .start(let name, let attributes, let selfClosing):
                if Self.dropped.contains(name) {
                    dropDepth += 1
                    continue
                }
                guard dropDepth == 0 else { continue }

                if name == "br" {
                    stack[stack.count - 1].children.append(.lineBreak)
                    continue
                }
                // Void elements never open a frame, whatever they claim.
                guard !selfClosing, let wrapper = wrapper(
                    for: name, attributes: attributes, thread: thread, board: board
                ) else {
                    continue
                }
                stack.append(Frame(tag: name, wrapper: wrapper, children: []))

            case .end(let name):
                if Self.dropped.contains(name) {
                    dropDepth = max(0, dropDepth - 1)
                    continue
                }
                guard dropDepth == 0 else { continue }
                close(name, in: &stack)
            }
        }

        // Anything left open is closed in order, so no text is lost.
        while stack.count > 1 {
            collapseTop(&stack)
        }
        return PostContent(nodes: stack[0].children)
    }

    // MARK: Frames

    private struct Frame {
        var tag: String?
        var wrapper: (([PostNode]) -> PostNode)?
        var children: [PostNode]

        init(tag: String?, wrapper: (([PostNode]) -> PostNode)? = nil, children: [PostNode]) {
            self.tag = tag
            self.wrapper = wrapper
            self.children = children
        }
    }

    /// Closes the innermost frame opened by `name`. A closing tag with no
    /// matching opener is ignored; mismatched nesting closes the frames in
    /// between, which is what browsers do.
    private func close(_ name: String, in stack: inout [Frame]) {
        guard stack.contains(where: { $0.tag == name }) else { return }
        while stack.count > 1 {
            let tag = stack[stack.count - 1].tag
            collapseTop(&stack)
            if tag == name { return }
        }
    }

    private func collapseTop(_ stack: inout [Frame]) {
        let frame = stack.removeLast()
        let node = frame.wrapper?(frame.children)
        if let node {
            stack[stack.count - 1].children.append(node)
        } else {
            // No wrapper: an unknown tag, whose children are kept inline.
            stack[stack.count - 1].children.append(contentsOf: frame.children)
        }
    }

    /// How a tag wraps its children, or `nil` when the tag contributes nothing
    /// but its contents.
    private func wrapper(
        for name: String,
        attributes: [String: String],
        thread: Int,
        board: String
    ) -> (([PostNode]) -> PostNode)? {
        let classes = Set(
            (attributes["class"] ?? "")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )

        switch name {
        case "strong", "b":
            return { .style(.bold, children: $0) }
        case "em", "i":
            return { .style(.italic, children: $0) }
        case "u":
            return { .style(.underline, children: $0) }
        case "s", "strike", "del":
            // 4chan's `<s>` is its spoiler tag, not a strikethrough. Rendering
            // one as the other would either reveal a spoiler or hide a joke.
            if dialect == .fourchan, name == "s" { return { .spoiler(children: $0) } }
            return { .style(.strikethrough, children: $0) }
        case "sup":
            return { .style(.superscript, children: $0) }
        case "sub":
            return { .style(.subscript, children: $0) }
        case "pre", "code", "fakecode":
            return { .code(children: $0) }

        case "span", "font", "div":
            if classes.contains("spoiler") { return { .spoiler(children: $0) } }
            // Greentext: `unkfunc` on 2ch, plain `quote` on 4chan.
            if classes.contains("unkfunc") { return { .quote(children: $0) } }
            if dialect == .fourchan, classes.contains("quote") {
                return { .quote(children: $0) }
            }
            if classes.contains("neuroslop") { return { .aiGenerated(children: $0) } }
            if classes.contains("u") { return { .style(.underline, children: $0) } }
            if classes.contains("s") { return { .style(.strikethrough, children: $0) } }
            if classes.contains("o") { return { .style(.overline, children: $0) } }
            // A plain span carries no meaning of its own.
            return { nodes in nodes.count == 1 ? nodes[0] : .style([], children: nodes) }

        case "a":
            if let reference = postReference(
                attributes: attributes, classes: classes, thread: thread, board: board
            ) {
                return { .postLink(reference, children: $0) }
            }
            guard let href = attributes["href"], !href.isEmpty else { return nil }
            // A protocol-relative href has no scheme and will not open. Both
            // sites write them; 4chan's cross-board links always do.
            let absolute = href.hasPrefix("//") ? "https:" + href : href
            return { .link(absolute, children: $0) }

        default:
            // Unknown tag: keep the text, drop the element.
            return nil
        }
    }

    /// Reads a `>>N` target from an anchor, preferring the data attributes the
    /// site sets over parsing the href.
    private func postReference(
        attributes: [String: String],
        classes: Set<String>,
        thread: Int,
        board: String
    ) -> PostReference? {
        let href = attributes["href"] ?? ""
        let looksLikeReply = switch dialect {
        case .wakaba:
            classes.contains("post-reply-link") || (href.contains("/res/") && href.contains("#"))
        case .fourchan:
            // Measured over a real thread, 428 of 437 quote links are the bare
            // `#p123` form; a recogniser keyed on `/thread/` would miss almost
            // all of them.
            classes.contains("quotelink") && href.contains("#p")
        }
        guard looksLikeReply else { return nil }

        // The href is parsed unconditionally because it is the only place the
        // board appears; the data attributes, when present, win for the numbers.
        let parsed = switch dialect {
        case .wakaba: Self.parseReplyHref(href)
        case .fourchan: Self.parseFourchanHref(href)
        }
        let postNum = attributes["data-num"].flatMap(Int.init) ?? parsed.postNum
        let threadNum = attributes["data-thread"].flatMap(Int.init) ?? parsed.threadNum

        guard let postNum else { return nil }
        return PostReference(
            board: parsed.board ?? board,
            threadNum: threadNum,
            postNum: postNum,
            isSameThread: threadNum == nil ? true : threadNum == thread
        )
    }

    /// Splits 4chan's `/g/thread/109832072#p109832099` into its parts.
    ///
    /// Kept apart from `parseReplyHref` rather than merged: `/res/N.html` and
    /// `/thread/N` differ enough that one function handling both would be worse
    /// at each. The common case has no path at all — a same-thread quote is
    /// written `#p123` and nothing else.
    static func parseFourchanHref(_ href: String) -> (board: String?, threadNum: Int?, postNum: Int?) {
        let postNum = href
            .split(separator: "#")
            .last
            .flatMap { Int($0.drop { !$0.isNumber }.prefix { $0.isNumber }) }

        guard let threadRange = href.range(of: "/thread/") else {
            // The bare `#p123` form: same thread, and the caller supplies both
            // the board and the thread.
            return (nil, nil, postNum)
        }
        let board = href[..<threadRange.lowerBound]
            .split(separator: "/")
            .last
            .map(String.init)
        let threadNum = Int(href[threadRange.upperBound...].prefix { $0.isNumber })
        // `/g/thread/123` with no anchor points at the thread itself.
        return (board, threadNum, postNum ?? threadNum)
    }

    /// Splits `/po/res/63459413.html#63459499` into its parts.
    static func parseReplyHref(_ href: String) -> (board: String?, threadNum: Int?, postNum: Int?) {
        guard let resRange = href.range(of: "/res/") else { return (nil, nil, nil) }

        let beforeRes = href[..<resRange.lowerBound]
        let board = beforeRes
            .split(separator: "/")
            .last
            .map(String.init)

        let afterRes = href[resRange.upperBound...]
        let threadPart = afterRes.prefix { $0.isNumber }
        let threadNum = Int(threadPart)

        let postNum = href
            .split(separator: "#")
            .last
            .flatMap { Int($0.prefix { $0.isNumber }) }

        return (board, threadNum, postNum)
    }
}
