import Foundation

/// A rule that hides posts matching it.
///
/// A value rather than the stored model, so the engine stays testable without a
/// database and rules can be evaluated off the main actor.
public struct AutohideRuleValue: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    /// The text or pattern to look for.
    public var pattern: String
    /// Treat `pattern` as a regular expression rather than literal text.
    public var isRegularExpression: Bool

    public var matchesSubject: Bool
    public var matchesComment: Bool
    public var matchesName: Bool
    public var matchesFileName: Bool

    /// Boards this applies to. Empty means every board.
    public var boards: Set<String>
    /// A single thread this applies to, when the rule was made from one.
    public var threadNum: Int?
    public var appliesToOriginalPostOnly: Bool
    public var appliesToSagedOnly: Bool

    public init(
        id: UUID = UUID(),
        pattern: String,
        isRegularExpression: Bool = false,
        matchesSubject: Bool = false,
        matchesComment: Bool = false,
        matchesName: Bool = false,
        matchesFileName: Bool = false,
        boards: Set<String> = [],
        threadNum: Int? = nil,
        appliesToOriginalPostOnly: Bool = false,
        appliesToSagedOnly: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.isRegularExpression = isRegularExpression
        self.matchesSubject = matchesSubject
        self.matchesComment = matchesComment
        self.matchesName = matchesName
        self.matchesFileName = matchesFileName
        self.boards = boards
        self.threadNum = threadNum
        self.appliesToOriginalPostOnly = appliesToOriginalPostOnly
        self.appliesToSagedOnly = appliesToSagedOnly
        self.isEnabled = isEnabled
    }

    /// True when the rule could ever match anything.
    public var isUsable: Bool {
        isEnabled
            && !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (matchesSubject || matchesComment || matchesName || matchesFileName)
            && patternError == nil
    }

    /// Why the pattern cannot be used, for the editor to show as you type.
    public var patternError: String? {
        guard isRegularExpression else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True when this rule applies in the given thread at all.
    func appliesTo(thread: ThreadKey) -> Bool {
        guard isEnabled else { return false }
        if !boards.isEmpty, !boards.contains(thread.board) { return false }
        if let threadNum, threadNum != thread.threadNum { return false }
        return true
    }
}

/// A rule made from a single post, living only inside one thread.
public enum LocalHideRule: Sendable, Hashable {
    /// Hide exactly this post.
    case post(num: Int)
    /// Hide this post and everything replying to it, however deep.
    case repliesTree(num: Int)
    /// Hide everything from this poster name.
    case name(String)
    /// Hide posts whose text is close to this.
    case similar(to: String)
}

/// Checks a rule against a piece of text, for the editor's live preview.
public enum AutohideRulePreview {
    public static func matches(_ rule: AutohideRuleValue, text: String) -> Bool {
        guard !text.isEmpty, rule.patternError == nil else { return false }
        guard !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        guard rule.isRegularExpression else {
            return text.localizedCaseInsensitiveContains(rule.pattern)
        }
        guard let expression = RegexCache.shared.expression(for: rule.pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }
}
