import Foundation
import NeechanAPI

/// Works out which posts are hidden.
///
/// Pure and synchronous: given the same thread and rules it always produces the
/// same set, which is what makes hiding testable without a database.
public enum FilterEngine {
    /// Post numbers to hide.
    ///
    /// - Parameters:
    ///   - index: supplies the parsed bodies, so rules match what a reader sees
    ///     rather than the HTML behind it, and the backlinks a replies tree needs.
    public static func hiddenPostNums(
        in posts: [Post],
        index: ReplyIndex,
        thread: ThreadKey,
        rules: [AutohideRuleValue],
        localRules: [LocalHideRule]
    ) -> Set<Int> {
        var hidden: Set<Int> = []

        let applicable = rules.filter { $0.isUsable && $0.appliesTo(thread: thread) }
        if !applicable.isEmpty {
            for post in posts {
                let text = index.content(of: post.num)?.plainText ?? ""
                if applicable.contains(where: { matches($0, post: post, commentText: text) }) {
                    hidden.insert(post.num)
                }
            }
        }

        for rule in localRules {
            hidden.formUnion(apply(rule, to: posts, index: index))
        }
        return hidden
    }

    /// Whether a thread should be kept off a board listing.
    ///
    /// The board list has only opening posts and no reply index, so it cannot
    /// use `hiddenPostNums`. Without this a rule marked "opening post only" did
    /// nothing at all: the listing never consulted the rules.
    public static func hidesThread(
        openingPost: Post,
        onBoard board: BoardRef,
        rules: [AutohideRuleValue]
    ) -> Bool {
        hidesThread(
            openingPost: openingPost,
            onBoard: board,
            rules: rules,
            commentText: {
                // The comment is HTML until something parses it, and a rule must
                // match what a reader sees rather than the markup.
                CommentHTMLParser(site: board.site)
                    .parse($0.comment, inThread: $0.num, onBoard: board.code)
                    .plainText
            }
        )
    }

    /// The same question, with the comment text supplied.
    ///
    /// The board list asks this for every thread on screen, several times per
    /// redraw, and parsing a comment is the most expensive thing in the answer.
    /// Taking the text lets the caller parse each opening post once, off the
    /// main actor, and keep it.
    ///
    /// - Parameter commentText: called only when a rule actually looks at the
    ///   comment, so a board with no such rule still parses nothing.
    public static func hidesThread(
        openingPost: Post,
        onBoard board: BoardRef,
        rules: [AutohideRuleValue],
        commentText: (Post) -> String
    ) -> Bool {
        let thread = ThreadKey(site: board.site, board: board.code, threadNum: openingPost.num)
        let applicable = rules.filter { $0.isUsable && $0.appliesTo(thread: thread) }
        guard !applicable.isEmpty else { return false }

        let text = applicable.contains(where: \.matchesComment) ? commentText(openingPost) : ""
        return applicable.contains { matches($0, post: openingPost, commentText: text) }
    }

    /// Which of these threads the rules hide.
    ///
    /// Answered once for a whole board rather than per row.
    public static func hiddenThreadNums(
        in openingPosts: [Post],
        onBoard board: BoardRef,
        rules: [AutohideRuleValue],
        commentText: (Post) -> String
    ) -> Set<Int> {
        guard !rules.isEmpty else { return [] }
        var hidden: Set<Int> = []
        for post in openingPosts
        where hidesThread(
            openingPost: post, onBoard: board, rules: rules, commentText: commentText
        ) {
            hidden.insert(post.num)
        }
        return hidden
    }

    // MARK: Global rules

    private static func matches(
        _ rule: AutohideRuleValue,
        post: Post,
        commentText: String
    ) -> Bool {
        if rule.appliesToOriginalPostOnly, !post.isOriginalPost { return false }
        if rule.appliesToSagedOnly, !post.isSage { return false }

        if rule.matchesSubject, contains(rule, in: post.subject) { return true }
        if rule.matchesComment, contains(rule, in: commentText) { return true }
        if rule.matchesName, contains(rule, in: post.name) { return true }
        if rule.matchesFileName,
           post.files.contains(where: { contains(rule, in: $0.fullName) }) {
            return true
        }
        return false
    }

    private static func contains(_ rule: AutohideRuleValue, in text: String) -> Bool {
        guard !text.isEmpty else { return false }

        guard rule.isRegularExpression else {
            return text.localizedCaseInsensitiveContains(rule.pattern)
        }
        guard let expression = RegexCache.shared.expression(for: rule.pattern) else {
            // A pattern that does not compile hides nothing, rather than
            // everything or crashing.
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: Local rules

    private static func apply(
        _ rule: LocalHideRule,
        to posts: [Post],
        index: ReplyIndex
    ) -> Set<Int> {
        switch rule {
        case .post(let num):
            return [num]

        case .repliesTree(let num):
            // The post itself and everything descending from it.
            return index.repliesTree(from: num).union([num])

        case .name(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return Set(
                posts
                    .filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
                    .map(\.num)
            )

        case .similar(let text):
            return Set(
                posts
                    .filter {
                        TextSimilarity.isSimilar(
                            index.content(of: $0.num)?.plainText ?? "",
                            text
                        )
                    }
                    .map(\.num)
            )
        }
    }
}
