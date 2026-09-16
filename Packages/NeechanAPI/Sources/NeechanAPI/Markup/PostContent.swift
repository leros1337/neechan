import Foundation

/// A parsed post body.
///
/// The three derived values below are walked once, here, rather than on every
/// read: the thread view, the search, the autohide rules and the reply index all
/// ask for `plainText` or `references`, several of them per row per render, and
/// each ask used to rebuild the string from the tree.
public struct PostContent: Sendable, Hashable {
    public let nodes: [PostNode]

    /// The body with all markup removed, for search, previews and accessibility.
    public let plainText: String

    /// Every `>>N` this post makes, in the order they appear.
    public let references: [PostReference]

    public let isEmpty: Bool

    /// Newlines in `plainText`.
    ///
    /// Counted from the text rather than from `.lineBreak` nodes, because a text
    /// node can carry a newline of its own. Backs the cheap check for whether a
    /// post is long enough to be worth measuring for truncation.
    public let lineBreakCount: Int

    public init(nodes: [PostNode]) {
        self.nodes = nodes

        var text = ""
        PostContent.appendText(of: nodes, to: &text)
        self.plainText = text

        var found: [PostReference] = []
        PostContent.collectReferences(in: nodes, into: &found)
        self.references = found

        self.isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.lineBreakCount = text.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    public static let empty = PostContent(nodes: [])

    // The derived values are pure functions of `nodes`, so identity is decided
    // by the tree alone. Hashing the text as well would walk it a second time
    // for no more precision.
    public static func == (lhs: PostContent, rhs: PostContent) -> Bool {
        lhs.nodes == rhs.nodes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(nodes)
    }

    /// Addresses of ordinary links in the post.
    public var externalLinks: [String] {
        var found: [String] = []
        PostContent.collectLinks(in: nodes, into: &found)
        return found
    }

    public var containsSpoiler: Bool { contains { if case .spoiler = $0 { true } else { false } } }
    public var containsQuote: Bool { contains { if case .quote = $0 { true } else { false } } }
    public var containsCode: Bool { contains { if case .code = $0 { true } else { false } } }
    public var isAIGenerated: Bool {
        contains { if case .aiGenerated = $0 { true } else { false } }
    }

    /// The styles applying to the character at `offset` in `plainText`.
    /// Used by the tests to assert nesting without depending on tree shape.
    public func styles(at offset: Int) -> PostStyle {
        var cursor = 0
        return PostContent.styles(in: nodes, seeking: offset, cursor: &cursor, inherited: [])
    }

    private func contains(_ predicate: (PostNode) -> Bool) -> Bool {
        PostContent.contains(in: nodes, predicate)
    }

    // MARK: Tree walks

    private static func appendText(of nodes: [PostNode], to text: inout String) {
        for node in nodes {
            switch node {
            case .text(let value): text += value
            case .lineBreak: text += "\n"
            case .style(_, let children),
                 .spoiler(let children),
                 .quote(let children),
                 .code(let children),
                 .aiGenerated(let children),
                 .link(_, let children),
                 .postLink(_, let children):
                appendText(of: children, to: &text)
            }
        }
    }

    private static func collectReferences(in nodes: [PostNode], into found: inout [PostReference]) {
        for node in nodes {
            switch node {
            case .postLink(let reference, let children):
                found.append(reference)
                collectReferences(in: children, into: &found)
            case .style(_, let children),
                 .spoiler(let children),
                 .quote(let children),
                 .code(let children),
                 .aiGenerated(let children),
                 .link(_, let children):
                collectReferences(in: children, into: &found)
            case .text, .lineBreak:
                break
            }
        }
    }

    private static func collectLinks(in nodes: [PostNode], into found: inout [String]) {
        for node in nodes {
            switch node {
            case .link(let url, let children):
                found.append(url)
                collectLinks(in: children, into: &found)
            case .style(_, let children),
                 .spoiler(let children),
                 .quote(let children),
                 .code(let children),
                 .aiGenerated(let children),
                 .postLink(_, let children):
                collectLinks(in: children, into: &found)
            case .text, .lineBreak:
                break
            }
        }
    }

    private static func contains(in nodes: [PostNode], _ predicate: (PostNode) -> Bool) -> Bool {
        for node in nodes {
            if predicate(node) { return true }
            switch node {
            case .style(_, let children),
                 .spoiler(let children),
                 .quote(let children),
                 .code(let children),
                 .aiGenerated(let children),
                 .link(_, let children),
                 .postLink(_, let children):
                if contains(in: children, predicate) { return true }
            case .text, .lineBreak:
                break
            }
        }
        return false
    }

    private static func styles(
        in nodes: [PostNode],
        seeking offset: Int,
        cursor: inout Int,
        inherited: PostStyle
    ) -> PostStyle {
        for node in nodes {
            switch node {
            case .text(let value):
                let next = cursor + value.count
                if offset >= cursor && offset < next { return inherited }
                cursor = next
            case .lineBreak:
                if offset == cursor { return inherited }
                cursor += 1
            case .style(let style, let children):
                let result = styles(
                    in: children, seeking: offset, cursor: &cursor,
                    inherited: inherited.union(style)
                )
                if !result.isEmpty || cursor > offset { return result }
            case .spoiler(let children),
                 .quote(let children),
                 .code(let children),
                 .aiGenerated(let children),
                 .link(_, let children),
                 .postLink(_, let children):
                let result = styles(
                    in: children, seeking: offset, cursor: &cursor, inherited: inherited
                )
                if !result.isEmpty || cursor > offset { return result }
            }
        }
        return inherited
    }
}

/// One element of a parsed post body.
public indirect enum PostNode: Sendable, Hashable {
    case text(String)
    case lineBreak
    /// Visual emphasis that can nest and combine.
    case style(PostStyle, children: [PostNode])
    /// Hidden until tapped.
    case spoiler(children: [PostNode])
    /// Greentext, rendered by the site as `span.unkfunc`.
    case quote(children: [PostNode])
    case code(children: [PostNode])
    /// A post the site marked as written by its assistant.
    case aiGenerated(children: [PostNode])
    /// An ordinary hyperlink.
    case link(String, children: [PostNode])
    /// A `>>N` reference to another post.
    case postLink(PostReference, children: [PostNode])
}

/// Visual emphasis. An option set because 2ch nests these freely.
public struct PostStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = PostStyle(rawValue: 1 << 0)
    public static let italic = PostStyle(rawValue: 1 << 1)
    public static let underline = PostStyle(rawValue: 1 << 2)
    public static let strikethrough = PostStyle(rawValue: 1 << 3)
    public static let overline = PostStyle(rawValue: 1 << 4)
    public static let superscript = PostStyle(rawValue: 1 << 5)
    public static let `subscript` = PostStyle(rawValue: 1 << 6)
    public static let monospace = PostStyle(rawValue: 1 << 7)
}

/// A `>>N` pointing at another post.
public struct PostReference: Sendable, Hashable {
    public let board: String?
    /// Thread the target lives in, when the link says so.
    public let threadNum: Int?
    public let postNum: Int
    /// True when the target is in the thread currently being read.
    public let isSameThread: Bool

    public init(board: String?, threadNum: Int?, postNum: Int, isSameThread: Bool) {
        self.board = board
        self.threadNum = threadNum
        self.postNum = postNum
        self.isSameThread = isSameThread
    }
}
