import Foundation
import os

/// One imageboard's API, as async methods.
///
/// An actor so the cookie jar and any in-flight coordination stay serialised.
/// Every failure is reported as a `DvachError`, so callers never see a raw
/// `URLError` or a decoding error from deeper down.
///
/// There is one of these whatever site is selected. The selection is read from
/// `site()` on every request, so switching imageboards re-points this client
/// rather than replacing it — which matters because eight collaborators hold it
/// and SwiftUI holds them.
public actor DvachClient {
    private let transport: any HTTPTransport
    private let site: SiteProvider
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder
    private let onChallenge: (@Sendable (URL) -> Void)?

    /// Board details per site, for a site whose catalog and thread answers do
    /// not carry them.
    ///
    /// Filled lazily by one `/boards.json` fetch and kept here rather than in a
    /// repository, because this is where the shortfall is and because the
    /// mapping cannot go looking for it from inside a synchronous decode.
    private var boardMetadata: [Imageboard: [String: Board]] = [:]

    public init(
        transport: any HTTPTransport,
        site: @escaping SiteProvider,
        retryPolicy: RetryPolicy = .default,
        // Told about every gate page, so one place can put the check in front of
        // the reader no matter which screen ran into it.
        onChallenge: (@Sendable (URL) -> Void)? = nil
    ) {
        self.transport = transport
        self.site = site
        self.retryPolicy = retryPolicy
        self.decoder = JSONDecoder()
        self.onChallenge = onChallenge
    }

    /// The site and mirror requests currently go to.
    public var currentSelection: SiteSelection { site() }

    /// The mirror requests currently go to. Meaningful only on 2ch.
    public var currentDomain: DvachDomain { site().mirror }

    /// What the selected site can do.
    public var capabilities: SiteCapabilities { site().capabilities }

    // MARK: Reading

    public func boards() async throws(DvachError) -> [Board] {
        let reply = try await send(.boards)
        let selection = site()
        let boards = try decode(reply, on: selection) { adapter, data in
            try adapter.boards(from: data, decoder: decoder)
        }
        // Remembered so a catalog or thread on a site that does not repeat the
        // board's details still has them.
        boardMetadata[selection.site] = Dictionary(
            boards.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return boards
    }

    public func catalog(board: String, byCreation: Bool = false) async throws(DvachError) -> CatalogResponse {
        let selection = site()
        let known = try await boardMetadata(board, on: selection)
        let reply = try await send(
            byCreation ? .catalogByCreation(board: board) : .catalog(board: board)
        )
        return try decode(reply, on: selection) { adapter, data in
            try adapter.catalog(
                from: data, board: known, endpoints: selection.endpoints, decoder: decoder
            )
        }
    }

    public func boardPage(board: String, page: Int) async throws(DvachError) -> BoardPage {
        let selection = site()
        let known = try await boardMetadata(board, on: selection)
        let reply = try await send(.boardPage(board: board, page: page))
        return try decode(reply, on: selection) { adapter, data in
            try adapter.boardPage(
                from: data, board: known, page: page,
                endpoints: selection.endpoints, decoder: decoder
            )
        }
    }

    public func thread(board: String, num: Int) async throws(DvachError) -> ThreadResponse {
        let selection = site()
        let known = try await boardMetadata(board, on: selection)
        let reply = try await send(.thread(board: board, thread: num))
        return try decode(reply, on: selection) { adapter, data in
            try adapter.thread(
                from: data, board: known, endpoints: selection.endpoints, decoder: decoder
            )
        }
    }

    /// Every thread on a board with how many posts it holds, in one request.
    ///
    /// The substitute for a count-only poll on a site that has none: a reader
    /// watching twenty threads across three boards costs three requests rather
    /// than twenty, which is cheaper than the per-thread poll it replaces.
    public func boardThreadCounts(board: String) async throws(DvachError) -> [Int: ThreadCount] {
        let selection = site()
        let reply = try await send(.boardThreads(board: board), policy: .poll)
        return try decode(reply, on: selection) { adapter, data in
            try adapter.threadCounts(from: data, decoder: decoder)
        }
    }

    /// The thread together with the bytes the server sent.
    ///
    /// Saving a thread for offline reading keeps the original JSON rather than
    /// re-encoding the models: it is a faithful copy, and it means the models
    /// never need to be writable.
    public func threadWithRawJSON(
        board: String,
        num: Int
    ) async throws(DvachError) -> (response: ThreadResponse, json: Data) {
        let selection = site()
        let known = try await boardMetadata(board, on: selection)
        let reply = try await send(.thread(board: board, thread: num))
        let response = try decode(reply, on: selection) { adapter, data in
            try adapter.thread(
                from: data, board: known, endpoints: selection.endpoints, decoder: decoder
            )
        }
        return (response, reply.data)
    }

    /// Posts numbered `sinceNum` and above. The first element is the anchor the
    /// caller already holds, which confirms the thread was not renumbered.
    public func after(
        board: String,
        thread: Int,
        sinceNum: Int
    ) async throws(DvachError) -> AfterResponse {
        try await get(
            AfterResponse.self,
            .after(board: board, thread: thread, sinceNum: sinceNum),
            envelope: \.error
        )
    }

    /// The post count for one thread, which is all the watcher needs.
    ///
    /// One attempt: this runs on a timer, so a failure is better left to the
    /// next pass than retried into a site that is already struggling.
    public func threadInfo(board: String, thread: Int) async throws(DvachError) -> InfoResponse {
        try await get(
            InfoResponse.self,
            .threadInfo(board: board, thread: thread),
            envelope: \.error,
            policy: .poll
        )
    }

    /// One post, for the quote popup when the post is not in the open thread.
    ///
    /// `inThread` is a hint for a site with no single-post endpoint: it fetches
    /// that thread and picks the post out. 2ch ignores it.
    public func post(
        board: String,
        num: Int,
        inThread: Int? = nil
    ) async throws(DvachError) -> SinglePostResponse {
        let selection = site()
        let known = try await boardMetadata(board, on: selection)
        let reply = try await send(.post(board: board, num: num, inThread: inThread))
        let response = try decode(reply, on: selection) { adapter, data in
            try adapter.singlePost(
                from: data, board: known, num: num,
                endpoints: selection.endpoints, decoder: decoder
            )
        }
        if let error = response.error { throw DvachError.api(error) }
        return response
    }

    public func search(board: String, text: String) async throws(DvachError) -> SearchResponse {
        try await get(SearchResponse.self, .search(board: board, text: text), envelope: \.error)
    }

    /// One page of a board's archive. Page `0` is its index.
    public func archive(board: String, page: Int) async throws(DvachError) -> ArchiveResponse {
        let selection = site()
        let reply = try await send(
            page <= 0 ? .archiveIndex(board: board) : .archivePage(board: board, page: page)
        )
        return try decode(reply, on: selection) { adapter, data in
            try adapter.archive(from: data, board: board, page: page, decoder: decoder)
        }
    }

    // MARK: Decoding

    /// Turns an answer into a model with the selected site's own reading of it.
    private func decode<T>(
        _ reply: HTTPReply,
        on selection: SiteSelection,
        _ body: (any SiteAdapter, Data) throws -> T
    ) throws(DvachError) -> T {
        do {
            return try body(selection.site.adapter, reply.data)
        } catch is UnsupportedBySite {
            throw DvachError.unsupported(selection.site)
        } catch {
            // A gate can arrive with a 200, so the body is checked here too
            // rather than only on the way out of `attemptSend`.
            //
            // Deliberately the real detector and not merely "this looks like a
            // page": a page that is *not* a gate cannot be passed, and offering
            // the reader a browser check for one puts them in a loop — answer
            // the check, retry, get the same page, be shown the check again.
            // Anything else is reported as unreadable, which is what it is, and
            // logged below so it can be identified.
            if ChallengeDetector.isChallenge(reply) {
                let url = reply.url ?? selection.endpoints.api
                Self.log.notice(
                    """
                    gated by \(ChallengeDetector.matchedMarker(reply) ?? "?", privacy: .public) \
                    status=\(reply.statusCode, privacy: .public) \
                    sent-cookie=\(reply.url.map { Self.cookieNames(for: $0) } ?? "none", privacy: .public)
                    """
                )
                onChallenge?(url)
                throw DvachError.cloudflareChallenge(url: url)
            }
            // Logged with the start of the body, because this is the failure
            // that tells the reader least and needs diagnosing most: attach
            // with `log stream --predicate 'subsystem == "com.lain.neechan"'`
            // and the answer that could not be read is there.
            Self.log.error(
                """
                decode failed for \(reply.url?.absoluteString ?? "?", privacy: .public): \
                \(String(describing: error), privacy: .public) \
                body: \(String(decoding: reply.data.prefix(256), as: UTF8.self), privacy: .public)
                """
            )
            throw DvachError.decoding(underlying: String(describing: error), url: reply.url)
        }
    }

    private static let log = Logger(subsystem: Signposts.subsystem, category: "client")

    /// The cookies the shared jar would send to a URL, by name.
    private static func cookieNames(for url: URL) -> String {
        (HTTPCookieStorage.shared.cookies(for: url) ?? [])
            .map(\.name)
            .sorted()
            .joined(separator: ",")
    }

    /// The board's own details, for a site that does not repeat them in every
    /// answer.
    ///
    /// Returns nil where the site does carry them, so 2ch pays nothing at all.
    /// The first miss fetches the whole board list once.
    private func boardMetadata(
        _ board: String,
        on selection: SiteSelection
    ) async throws(DvachError) -> Board? {
        guard selection.site.adapter.needsBoardMetadata else { return nil }
        if let known = boardMetadata[selection.site]?[board] { return known }
        _ = try await boards()
        // Still missing after a fetch: a board code the site does not have, or
        // one typed by hand. A placeholder keeps the thread readable rather
        // than failing the whole request over its metadata.
        return boardMetadata[selection.site]?[board] ?? Board(id: board, defaultName: "Anonymous")
    }

    // MARK: Writing

    public func report(
        board: String,
        thread: Int,
        posts: [Int],
        comment: String
    ) async throws(DvachError) -> ActionResponse {
        try await get(
            ActionResponse.self,
            .report(board: board, thread: thread, posts: posts, comment: comment),
            envelope: \.error
        )
    }

    public func vote(board: String, num: Int, isLike: Bool) async throws(DvachError) -> ActionResponse {
        try await get(
            ActionResponse.self,
            isLike ? .like(board: board, num: num) : .dislike(board: board, num: num),
            envelope: \.error
        )
    }

    public func passcodeLogin(passcode: String) async throws(DvachError) -> PasscodeResponse {
        try await get(PasscodeResponse.self, .passcodeLogin(passcode: passcode), envelope: \.error)
    }

    // MARK: Captcha

    /// Asks for 4chan's slider captcha.
    ///
    /// Almost all of this feature is the absence of code. The endpoint sits
    /// behind a browser check, and `ChallengeDetector` reads the `cf-mitigated`
    /// header before anything else, so a gated answer already becomes
    /// `.cloudflareChallenge`, already reaches `onChallenge`, and already skips
    /// the retry loop rather than hammering the gate. What is left is one
    /// request and one model.
    ///
    /// Nothing here solves the puzzle. The images are handed to the reader.
    public func fourchanCaptcha(
        board: String,
        thread: Int? = nil
    ) async throws(DvachError) -> FourchanCaptcha {
        let selection = site()
        // One attempt: the answer is a gate or a puzzle, and neither improves
        // by being asked for three times in a row.
        let reply = try await send(.sliderCaptcha(board: board, thread: thread), policy: .none)
        let captcha = try decode(reply, on: selection) { _, data in
            try decoder.decode(FourchanCaptcha.self, from: data)
        }
        // A refusal carries a cooldown rather than a puzzle. Reported as a rate
        // limit so the posting layer's existing classification applies to it.
        Self.log.notice(
            """
            captcha answered: challenge=\(captcha.challenge ?? "none", privacy: .public) \
            image=\(captcha.image?.count ?? 0, privacy: .public) \
            background=\(captcha.background?.count ?? 0, privacy: .public) \
            ttl=\(captcha.ttl ?? -1, privacy: .public) \
            error=\(captcha.error ?? "none", privacy: .public)
            """
        )
        if let error = captcha.error, !error.isEmpty {
            throw DvachError.api(DvachAPIError(code: .rateLimited, message: error))
        }
        return captcha
    }

    public func captchaSettings(board: String) async throws(DvachError) -> CaptchaSettings {
        try await get(CaptchaSettings.self, .captchaSettings(board: board))
    }

    public func captchaID(board: String, thread: Int?) async throws(DvachError) -> CaptchaIDResponse {
        // The envelope is not raised here: `result` carries outcomes such as
        // "a passcode means no captcha", which the session interprets.
        try await get(CaptchaIDResponse.self, .emojiCaptchaID(board: board, thread: thread))
    }

    public func emojiCaptchaShow(id: String) async throws(DvachError) -> EmojiCaptchaStep {
        let reply = try await get(EmojiCaptchaReply.self, .emojiCaptchaShow(id: id))
        guard let image = reply.image, let keyboard = reply.keyboard else {
            throw DvachError.decoding(
                underlying: "the captcha did not return a keyboard", url: nil
            )
        }
        return EmojiCaptchaStep(image: image, keyboard: keyboard)
    }

    public func emojiCaptchaClick(
        id: String,
        emojiIndex: Int
    ) async throws(DvachError) -> EmojiCaptchaSession.State {
        let reply = try await get(
            EmojiCaptchaReply.self,
            .emojiCaptchaClick(id: id, emojiIndex: emojiIndex)
        )
        if let token = reply.success, !token.isEmpty {
            return .solved(token)
        }
        if let image = reply.image, let keyboard = reply.keyboard {
            return .challenge(EmojiCaptchaStep(image: image, keyboard: keyboard))
        }
        if let error = reply.error {
            throw DvachError.api(error)
        }
        throw DvachError.decoding(underlying: "unrecognised captcha reply", url: nil)
    }

    // MARK: Plumbing

    /// Sends `endpoint`, decodes the body, and raises the envelope error when
    /// the payload carries one.
    private func get<T: Decodable>(
        _ type: T.Type,
        _ endpoint: ImageboardEndpoint,
        envelope: (@Sendable (T) -> DvachAPIError?)? = nil,
        policy: RetryPolicy? = nil
    ) async throws(DvachError) -> T {
        let reply = try await send(endpoint, policy: policy)
        let value: T
        do {
            value = try decoder.decode(T.self, from: reply.data)
        } catch {
            throw DvachError.decoding(underlying: String(describing: error), url: reply.url)
        }
        if let apiError = envelope?(value), apiError.code != .none {
            throw DvachError.api(apiError)
        }
        return value
    }

    /// Performs the request, retrying transient failures and turning anything
    /// that is not a usable 2xx into a `DvachError`.
    private func send(
        _ endpoint: ImageboardEndpoint,
        policy: RetryPolicy? = nil
    ) async throws(DvachError) -> HTTPReply {
        // The retry loop lives in a function with an untyped `throws`.
        //
        // Written with `throws(DvachError)` it crashed the app on any dropped
        // connection: a loop that awaits, catches and then leaves the scope
        // corrupts the task allocator ("freed pointer was not the last
        // allocation"). Converting the error at this boundary keeps the typed
        // error the callers rely on.
        do {
            return try await attemptSend(endpoint, policy: policy ?? retryPolicy)
        } catch let error as DvachError {
            throw error
        } catch {
            throw DvachError.transport(underlying: error)
        }
    }

    private func attemptSend(
        _ endpoint: ImageboardEndpoint,
        policy: RetryPolicy
    ) async throws -> HTTPReply {
        let selection = site()
        guard let request = endpoint.request(for: selection) else {
            throw DvachError.unsupported(selection.site)
        }
        var lastError: DvachError?
        /// What the server asked for on the previous attempt, in seconds.
        var retryAfter: Double?

        for attempt in 0..<policy.maxAttempts {
            guard let delay = policy.delay(beforeAttempt: attempt, retryAfter: retryAfter) else {
                break
            }
            if delay > .zero {
                // `Task.sleep` is called directly rather than through an
                // injected closure. Awaiting a stored `async` closure inside
                // this loop corrupts the task allocator, which crashed the app
                // on any dropped connection; tests skip the wait by passing a
                // `RetryPolicy` of zero delays instead.
                try? await Task.sleep(for: delay)
                if Task.isCancelled {
                    throw DvachError.transport(underlying: CancellationError())
                }
            }
            retryAfter = nil

            let reply: HTTPReply
            do {
                reply = try await transport.send(request)
            } catch {
                // A dropped connection is worth another go; a cancellation is not.
                if error is CancellationError { throw DvachError.transport(underlying: error) }
                lastError = .transport(underlying: error)
                continue
            }

            // A gate page must reach the user, not the retry loop: repeating the
            // request cannot pass a challenge.
            if ChallengeDetector.isChallenge(reply) {
                let url = reply.url ?? selection.endpoints.api
                // Which gate, and with what already in the jar: Cloudflare
                // refusing the connection and the site's own script refusing a
                // replayed cookie look identical to the reader and need
                // completely different answers.
                Self.log.notice(
                    """
                    gated by \(ChallengeDetector.matchedMarker(reply) ?? "?", privacy: .public) \
                    status=\(reply.statusCode, privacy: .public) \
                    url=\(url.absoluteString, privacy: .public) \
                    sent-cookies=\(Self.cookieNames(for: url), privacy: .public) \
                    ua=\(UserAgent.current, privacy: .public)
                    """
                )
                onChallenge?(url)
                throw DvachError.cloudflareChallenge(url: url)
            }

            if reply.isSuccess { return reply }

            // Being told to slow down and answering with three more requests is
            // how a client gets itself blocked. The caller decides what to do
            // with it; the watcher backs the thread off to its longest wait.
            if reply.statusCode == 429 {
                throw DvachError.http(status: 429, url: reply.url)
            }

            // The server's own errors arrive as a 200 with an envelope, so a 4xx
            // here is a genuine client error and will not change on a retry.
            guard reply.statusCode >= 500 else {
                throw DvachError.http(status: reply.statusCode, url: reply.url)
            }
            retryAfter = reply.header("retry-after").flatMap(Double.init)
            lastError = .http(status: reply.statusCode, url: reply.url)
        }

        throw lastError ?? .http(status: -1, url: nil)
    }
}
