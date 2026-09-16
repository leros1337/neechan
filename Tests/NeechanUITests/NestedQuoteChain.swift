import Foundation

/// A post that quotes a post that itself quotes a post.
///
/// Found from the site rather than assumed: threads die, so a hard-coded chain
/// would rot within a day, and tapping quotes at random almost never lands on
/// one because most quoted posts quote nothing.
struct NestedQuoteChain {
    let board: String
    let thread: Int
    /// Quotes `postB`.
    let postA: Int
    /// Quotes `postC`.
    let postB: Int
    let postC: Int

    static func find(board: String = "b", threadsToTry: Int = 6) -> NestedQuoteChain? {
        guard let catalog = fetch("https://2ch.org/\(board)/catalog.json"),
              let threads = catalog["threads"] as? [[String: Any]]
        else {
            return nil
        }

        let busiest = threads
            .sorted { ($0["posts_count"] as? Int ?? 0) > ($1["posts_count"] as? Int ?? 0) }
            .prefix(threadsToTry)

        for summary in busiest {
            guard
                let num = summary["num"] as? Int,
                let chain = chain(inThread: num, board: board)
            else {
                continue
            }
            return chain
        }
        return nil
    }

    private static func chain(inThread thread: Int, board: String) -> NestedQuoteChain? {
        guard
            let response = fetch("https://2ch.org/\(board)/res/\(thread).json"),
            let groups = response["threads"] as? [[String: Any]]
        else {
            return nil
        }

        var quotes: [Int: [Int]] = [:]
        for group in groups {
            for post in group["posts"] as? [[String: Any]] ?? [] {
                guard let num = post["num"] as? Int else { continue }
                quotes[num] = quoted(in: post["comment"] as? String ?? "")
            }
        }

        for (postA, targets) in quotes {
            for postB in targets {
                if let deeper = quotes[postB]?.first {
                    return NestedQuoteChain(
                        board: board, thread: thread, postA: postA, postB: postB, postC: deeper
                    )
                }
            }
        }
        return nil
    }

    /// The post numbers a comment quotes, read from the anchors the site emits.
    private static func quoted(in comment: String) -> [Int] {
        guard let pattern = try? NSRegularExpression(pattern: "data-num=\"(\\d+)\"") else {
            return []
        }
        let range = NSRange(comment.startIndex..., in: comment)
        return pattern.matches(in: comment, range: range).compactMap { match in
            Range(match.range(at: 1), in: comment).flatMap { Int(comment[$0]) }
        }
    }

    private static func fetch(_ address: String) -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        // A browser-like agent so the site answers this lookup as it answers
        // the app. Spelled out rather than shared with the app: a UI test runs
        // in its own process and links none of the app's packages.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30

        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data else { return }
            result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        .resume()
        _ = done.wait(timeout: .now() + 35)
        return result
    }
}
