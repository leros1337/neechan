import Foundation
import SwiftData

/// A thread the reader does not want to see on the board.
@Model
public final class HiddenThread {
    #Unique<HiddenThread>([\.board, \.threadNum])

    public var board: String = ""
    public var threadNum: Int = 0
    public var title: String = ""
    public var hiddenAt: Date = Date.distantPast

    public init(board: String, threadNum: Int, title: String, hiddenAt: Date = .now) {
        self.board = board
        self.threadNum = threadNum
        self.title = title
        self.hiddenAt = hiddenAt
    }
}

/// A hide made from one post, living only inside its thread.
@Model
public final class HiddenPostRule {
    #Index<HiddenPostRule>([\.board, \.threadNum])

    public var board: String = ""
    public var threadNum: Int = 0
    /// Which kind of hide this is; see `LocalHideRule`.
    public var kindRaw: String = ""
    public var postNum: Int?
    public var name: String?
    public var similarText: String?
    public var createdAt: Date = Date.distantPast

    public init(
        board: String,
        threadNum: Int,
        rule: LocalHideRule,
        createdAt: Date = .now
    ) {
        self.board = board
        self.threadNum = threadNum
        self.createdAt = createdAt

        switch rule {
        case .post(let num):
            kindRaw = "post"
            postNum = num
        case .repliesTree(let num):
            kindRaw = "repliesTree"
            postNum = num
        case .name(let value):
            kindRaw = "name"
            name = value
        case .similar(let text):
            kindRaw = "similar"
            similarText = text
        }
    }

    /// The rule this row represents, or nil when the row is malformed.
    public var rule: LocalHideRule? {
        switch kindRaw {
        case "post": postNum.map { .post(num: $0) }
        case "repliesTree": postNum.map { .repliesTree(num: $0) }
        case "name": name.map { .name($0) }
        case "similar": similarText.map { .similar(to: $0) }
        default: nil
        }
    }
}

/// A rule that hides posts across threads.
@Model
public final class AutohideRule {
    #Index<AutohideRule>([\.sortOrder])

    public var id: UUID = UUID()
    public var isEnabled: Bool = true
    public var pattern: String = ""
    public var isRegularExpression: Bool = false

    public var matchesSubject: Bool = false
    public var matchesComment: Bool = true
    public var matchesName: Bool = false
    public var matchesFileName: Bool = false

    /// Empty means every board.
    public var boards: [String] = []
    public var threadNum: Int?
    public var appliesToOriginalPostOnly: Bool = false
    public var appliesToSagedOnly: Bool = false

    public var createdAt: Date = Date.distantPast
    public var sortOrder: Int = 0

    public init(value: AutohideRuleValue, createdAt: Date = .now, sortOrder: Int = 0) {
        self.id = value.id
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        apply(value)
    }

    public func apply(_ value: AutohideRuleValue) {
        isEnabled = value.isEnabled
        pattern = value.pattern
        isRegularExpression = value.isRegularExpression
        matchesSubject = value.matchesSubject
        matchesComment = value.matchesComment
        matchesName = value.matchesName
        matchesFileName = value.matchesFileName
        boards = value.boards.sorted()
        threadNum = value.threadNum
        appliesToOriginalPostOnly = value.appliesToOriginalPostOnly
        appliesToSagedOnly = value.appliesToSagedOnly
    }

    public var value: AutohideRuleValue {
        AutohideRuleValue(
            id: id,
            pattern: pattern,
            isRegularExpression: isRegularExpression,
            matchesSubject: matchesSubject,
            matchesComment: matchesComment,
            matchesName: matchesName,
            matchesFileName: matchesFileName,
            boards: Set(boards),
            threadNum: threadNum,
            appliesToOriginalPostOnly: appliesToOriginalPostOnly,
            appliesToSagedOnly: appliesToSagedOnly,
            isEnabled: isEnabled
        )
    }
}
