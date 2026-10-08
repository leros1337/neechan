import Foundation

/// Reading what 4chan says after a post.
///
/// Asked for JSON, as the site's quick reply asks, the answer is `{error}` or
/// `{tid, pid}`. Anything else is the page the full form gets: success is an
/// HTML comment carrying the two numbers, and a refusal is a
/// `<span id="errmsg">` with a sentence in it. None of it is documented; all of
/// it is what the site's own scripts read.
enum FourchanPostingReply {
    /// Reads whichever of the two came back.
    static func outcome(from reply: HTTPReply) throws(PostingError) -> PostingOutcome {
        let text = String(decoding: reply.data, as: UTF8.self)
        let trimmed = text.drop { $0.isWhitespace }
        if reply.contentType == "application/json" || trimmed.hasPrefix("{") {
            return try outcome(fromJSON: reply.data)
        }
        // The quick reply reports a failed status as it is, and a page that
        // says nothing either way is no more readable for having come back.
        if !reply.isSuccess, errorMessage(in: text) == nil, numbers(in: text) == nil {
            throw PostingError(
                code: .unknown(reply.statusCode),
                message: String(
                    localized: "The site answered with error \(reply.statusCode).",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }
        return try outcome(from: text)
    }

    /// `{"error": "…"}` or `{"tid": 123, "pid": 456}`.
    static func outcome(fromJSON data: Data) throws(PostingError) -> PostingOutcome {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = object["error"] as? String, let message = plainText(error) {
            throw PostingError(code: code(for: message), message: message)
        }
        guard let post = integer(object["pid"]) else { throw unconfirmed }
        let thread = integer(object["tid"]) ?? 0
        return thread == 0 || thread == post ? .threadCreated(num: post) : .posted(num: post)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static var unconfirmed: PostingError {
        PostingError(
            code: .unknown(0),
            message: String(
                localized: "The site did not say whether the post went through.",
                bundle: .module.forAppLanguage(),
                locale: AppLocale.current
            )
        )
    }

    /// Pulls the outcome out of the page.
    static func outcome(from html: String) throws(PostingError) -> PostingOutcome {
        if let error = errorMessage(in: html) {
            throw PostingError(code: code(for: error), message: error)
        }
        guard let (thread, post) = numbers(in: html) else { throw unconfirmed }
        // `thread:0` is what a new thread comes back as, with the post number
        // standing in for both.
        return thread == 0 || thread == post ? .threadCreated(num: post) : .posted(num: post)
    }

    /// `<!-- thread:123456,no:123457 -->`
    static func numbers(in html: String) -> (thread: Int, post: Int)? {
        guard let range = html.range(of: "thread:") else { return nil }
        let rest = html[range.upperBound...]
        let thread = Int(rest.prefix { $0.isNumber })
        guard
            let noRange = rest.range(of: "no:"),
            let post = Int(rest[noRange.upperBound...].prefix { $0.isNumber }),
            let thread
        else {
            return nil
        }
        return (thread, post)
    }

    /// The text of `<span id="errmsg">…</span>`, with its tags taken out.
    static func errorMessage(in html: String) -> String? {
        guard let idRange = html.range(of: "id=\"errmsg\"") else { return nil }
        let afterID = html[idRange.upperBound...]
        guard let open = afterID.firstIndex(of: ">") else { return nil }
        let body = afterID[afterID.index(after: open)...]
        guard let close = body.range(of: "</span>") else { return nil }

        return plainText(String(body[..<close.lowerBound]))
    }

    /// The site's sentence without its markup. Moderators and the error
    /// template both put links in these, and the JSON carries the same HTML.
    static func plainText(_ html: String) -> String? {
        let stripped = HTMLEntities.decode(html)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Maps the site's sentence onto a code the posting layer already knows.
    ///
    /// Worth doing rather than reporting everything as unknown: the existing
    /// classification is what decides whether to ask for a fresh captcha, offer
    /// a retry, or stop — and all three answers are right here too.
    static func code(for message: String) -> DvachErrorCode {
        let text = message.lowercased()
        if text.contains("captcha") { return .invalidCaptcha }
        // The captcha's own refusal, which the post can be answered with too.
        if text.contains("wait a while") { return .rateLimited }
        if text.contains("must wait") || text.contains("wait longer") { return .postingTooFast }
        if text.contains("flood detected") { return .postingTooFast }
        if text.contains("thread is closed") || text.contains("thread specified does not exist") {
            return .threadClosed
        }
        if text.contains("banned") || text.contains("blocked") { return .banned }
        if text.contains("spam") { return .banned }
        if text.contains("no text entered") { return .emptyPost }
        if text.contains("no file selected") { return .emptyOriginalPost }
        if text.contains("file too large") { return .fileTooBig }
        if text.contains("upload failed") || text.contains("format not supported") {
            return .fileNotSupported
        }
        if text.contains("duplicate file") { return .similarFile }
        // Reported verbatim rather than guessed at: the reader sees the site's
        // own words, and nothing is wrongly marked retryable.
        return .unknown(0)
    }
}
