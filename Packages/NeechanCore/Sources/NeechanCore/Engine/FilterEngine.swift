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
        onBoard board: String,
        rules: [AutohideRuleValue]
    ) -> Bool {
        let thread = ThreadKey(board: board, threadNum: openingPost.num)
        let applicable = rules.filter { $0.isUsable && $0.appliesTo(thread: thread) }
        guard !applicable.isEmpty else { return false }

        // The comment is HTML until something parses it, and a rule must match
        // what a reader sees rather than the markup. Parsing is skipped when no
        // applicable rule looks at the comment at all.
        let commentText = applicable.contains(where: \.matchesComment)
            ? CommentHTMLParser()
                .parse(openingPost.comment, inThread: thread.threadNum, onBoard: board)
                .plainText
            : ""
        return applicable.contains { matches($0, post: openingPost, commentText: commentText) }
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
