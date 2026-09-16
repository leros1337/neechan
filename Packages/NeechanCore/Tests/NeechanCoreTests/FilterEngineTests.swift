import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

private func post(
    _ num: Int,
    comment: String = "",
    subject: String = "",
    name: String = "",
    email: String = "",
    fileName: String? = nil,
    isOP: Bool = false
) throws -> Post {
    var object: [String: Any] = [
        "num": num, "parent": isOP ? 0 : 100, "board": "b",
        "comment": comment, "subject": subject, "name": name, "email": email,
    ]
    if let fileName {
        object["files"] = [[
            "name": fileName, "fullname": fileName, "displayname": fileName,
            "path": "/b/src/100/\(fileName)", "thumbnail": "/b/thumb/100/\(fileName)",
            "type": 1, "size": 1, "width": 1, "height": 1, "tn_width": 1, "tn_height": 1,
        ]]
    }
    return try JSONDecoder().decode(
        Post.self, from: try JSONSerialization.data(withJSONObject: object)
    )
}

@Suite("Filter engine")
struct FilterEngineTests {
    private let thread = ThreadKey(board: "b", threadNum: 100)

    private func evaluate(
        _ posts: [Post],
        rules: [AutohideRuleValue] = [],
        local: [LocalHideRule] = []
    ) -> Set<Int> {
        let index = ReplyIndex(posts: posts, thread: thread)
        return FilterEngine.hiddenPostNums(
            in: posts, index: index, thread: thread, rules: rules, localRules: local
        )
    }

    // MARK: Global rules

    @Test("a comment rule hides the posts whose text matches")
    func matchesComment() throws {
        let posts = try [post(1, comment: "реклама казино"), post(2, comment: "обычный пост")]
        let rule = AutohideRuleValue(pattern: "казино", matchesComment: true)
        #expect(evaluate(posts, rules: [rule]) == [1])
    }

    @Test("the rule matches the rendered text, not the markup")
    func ignoresMarkup() throws {
        let posts = try [post(1, comment: #"<span class="spoiler">тайна</span>"#)]
        #expect(evaluate(posts, rules: [AutohideRuleValue(pattern: "spoiler", matchesComment: true)]).isEmpty)
        #expect(evaluate(posts, rules: [AutohideRuleValue(pattern: "тайна", matchesComment: true)]) == [1])
    }

    @Test("a subject rule only looks at subjects")
    func matchesSubject() throws {
        let posts = try [post(1, comment: "спам", subject: "тема"), post(2, subject: "спам")]
        let rule = AutohideRuleValue(pattern: "спам", matchesSubject: true)
        #expect(evaluate(posts, rules: [rule]) == [2])
    }

    @Test("a name rule only looks at names")
    func matchesName() throws {
        let posts = try [post(1, name: "Вася"), post(2, name: "Петя")]
        #expect(evaluate(posts, rules: [AutohideRuleValue(pattern: "Вася", matchesName: true)]) == [1])
    }

    @Test("a file name rule looks at attachments")
    func matchesFileName() throws {
        let posts = try [post(1, fileName: "реклама.jpg"), post(2, fileName: "котик.jpg")]
        let rule = AutohideRuleValue(pattern: "реклама", matchesFileName: true)
        #expect(evaluate(posts, rules: [rule]) == [1])
    }

    @Test("an opening-post rule spares the replies")
    func opOnlyRule() throws {
        let posts = try [post(100, comment: "спам", isOP: true), post(101, comment: "спам")]
        let rule = AutohideRuleValue(pattern: "спам", matchesComment: true, appliesToOriginalPostOnly: true)
        #expect(evaluate(posts, rules: [rule]) == [100])
    }

    @Test("a sage rule only hides posts sent with sage")
    func sageOnlyRule() throws {
        let posts = try [post(1, comment: "x", email: "sage"), post(2, comment: "x")]
        let rule = AutohideRuleValue(pattern: "x", matchesComment: true, appliesToSagedOnly: true)
        #expect(evaluate(posts, rules: [rule]) == [1])
    }

    @Test("a rule scoped to other boards does nothing here")
    func boardScope() throws {
        let posts = try [post(1, comment: "спам")]
        let elsewhere = AutohideRuleValue(pattern: "спам", matchesComment: true, boards: ["vg"])
        let here = AutohideRuleValue(pattern: "спам", matchesComment: true, boards: ["b"])
        #expect(evaluate(posts, rules: [elsewhere]).isEmpty)
        #expect(evaluate(posts, rules: [here]) == [1])
    }

    @Test("a rule scoped to another thread does nothing here")
    func threadScope() throws {
        let posts = try [post(1, comment: "спам")]
        let other = AutohideRuleValue(pattern: "спам", matchesComment: true, threadNum: 999)
        #expect(evaluate(posts, rules: [other]).isEmpty)
    }

    @Test("a disabled rule is ignored")
    func disabledRule() throws {
        let posts = try [post(1, comment: "спам")]
        let rule = AutohideRuleValue(pattern: "спам", matchesComment: true, isEnabled: false)
        #expect(evaluate(posts, rules: [rule]).isEmpty)
    }

    @Test("a rule matching nothing hides nothing")
    func ruleWithNoFieldsSelected() throws {
        let posts = try [post(1, comment: "спам")]
        #expect(evaluate(posts, rules: [AutohideRuleValue(pattern: "спам")]).isEmpty)
    }

    @Test("a plain-text rule is matched literally, not as a pattern")
    func literalMatching() throws {
        let posts = try [post(1, comment: "стоит 5$ (дёшево)")]
        let literal = AutohideRuleValue(pattern: "5$ (дёшево)", isRegularExpression: false, matchesComment: true)
        #expect(evaluate(posts, rules: [literal]) == [1])
    }

    @Test("a regular expression rule is matched as one")
    func regularExpressionMatching() throws {
        let posts = try [post(1, comment: "заказ 12345"), post(2, comment: "без цифр")]
        let rule = AutohideRuleValue(pattern: #"\d{5}"#, isRegularExpression: true, matchesComment: true)
        #expect(evaluate(posts, rules: [rule]) == [1])
    }

    @Test("an invalid regular expression hides nothing rather than crashing")
    func invalidRegularExpression() throws {
        let posts = try [post(1, comment: "что угодно")]
        let rule = AutohideRuleValue(pattern: "[unclosed", isRegularExpression: true, matchesComment: true)
        #expect(evaluate(posts, rules: [rule]).isEmpty)
        #expect(AutohideRuleValue(pattern: "[unclosed", isRegularExpression: true).patternError != nil)
        #expect(AutohideRuleValue(pattern: "ok", isRegularExpression: true).patternError == nil)
    }

    @Test("matching ignores case")
    func caseInsensitive() throws {
        let posts = try [post(1, comment: "СПАМ")]
        #expect(evaluate(posts, rules: [AutohideRuleValue(pattern: "спам", matchesComment: true)]) == [1])
    }

    // MARK: Local rules

    @Test("hiding one post hides only that post")
    func localHidePost() throws {
        let posts = try [post(1), post(2)]
        #expect(evaluate(posts, local: [.post(num: 1)]) == [1])
    }

    @Test("hiding a replies tree hides the whole chain below it")
    func localHideRepliesTree() throws {
        let posts = try [
            post(1),
            post(2, comment: #"<a class="post-reply-link" data-thread="100" data-num="1">&gt;&gt;1</a>"#),
            post(3, comment: #"<a class="post-reply-link" data-thread="100" data-num="2">&gt;&gt;2</a>"#),
            post(4),
        ]
        // The post itself and everything descending from it.
        #expect(evaluate(posts, local: [.repliesTree(num: 1)]) == [1, 2, 3])
    }

    @Test("hiding by name hides that poster's posts")
    func localHideName() throws {
        let posts = try [post(1, name: "Вася"), post(2, name: "Петя")]
        #expect(evaluate(posts, local: [.name("Вася")]) == [1])
    }

    @Test("hiding similar posts catches near-duplicates but not unrelated ones")
    func localHideSimilar() throws {
        let copypasta = "Купите наш товар прямо сейчас, это лучшее предложение на рынке сегодня"
        let posts = try [
            post(1, comment: copypasta),
            post(2, comment: copypasta + " Спешите!"),
            post(3, comment: "Совершенно другой текст про котиков и погоду за окном"),
        ]
        let hidden = evaluate(posts, local: [.similar(to: copypasta)])
        #expect(hidden.contains(1))
        #expect(hidden.contains(2))
        #expect(hidden.contains(3) == false)
    }

    @Test("rules combine rather than override")
    func rulesCombine() throws {
        let posts = try [post(1, comment: "спам"), post(2, name: "Вася"), post(3)]
        let hidden = evaluate(
            posts,
            rules: [AutohideRuleValue(pattern: "спам", matchesComment: true)],
            local: [.name("Вася")]
        )
        #expect(hidden == [1, 2])
    }

    @Test("no rules hides nothing")
    func noRules() throws {
        #expect(evaluate(try [post(1), post(2)]).isEmpty)
    }
}

@Suite("Text similarity")
struct TextSimilarityTests {
    @Test("identical text scores one")
    func identical() {
        #expect(TextSimilarity.score("привет мир как дела", "привет мир как дела") == 1)
    }

    @Test("unrelated text scores zero")
    func disjoint() {
        #expect(TextSimilarity.score("кошки собаки птицы", "автомобили поезда") == 0)
    }

    @Test("punctuation and case do not matter")
    func normalises() {
        #expect(TextSimilarity.score("Привет, МИР!", "привет мир") > 0.9)
    }

    @Test("a longer version of the same text still scores high")
    func extendedText() {
        let base = "купите наш товар прямо сейчас лучшее предложение"
        #expect(TextSimilarity.score(base, base + " спешите успеть") > 0.7)
    }

    @Test("empty text is not similar to anything")
    func emptyText() {
        #expect(TextSimilarity.score("", "привет") == 0)
        #expect(TextSimilarity.score("", "") == 0)
    }

    @Test("the threshold is high enough to spare different posts")
    func thresholdIsSane() {
        #expect(
            TextSimilarity.score("я согласен с тобой полностью", "я не согласен с этим")
                < TextSimilarity.defaultThreshold
        )
    }
}
