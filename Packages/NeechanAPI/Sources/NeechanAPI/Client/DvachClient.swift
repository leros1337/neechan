import Foundation

/// The 2ch API, as async methods.
///
/// An actor so the cookie jar and any in-flight coordination stay serialised.
/// Every failure is reported as a `DvachError`, so callers never see a raw
/// `URLError` or a decoding error from deeper down.
public actor DvachClient {
    private let transport: any HTTPTransport
    private let domain: DomainProvider
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder
    private let onChallenge: (@Sendable (URL) -> Void)?

    public init(
        transport: any HTTPTransport,
        domain: @escaping DomainProvider,
        retryPolicy: RetryPolicy = .default,
        // Told about every gate page, so one place can put the check in front of
        // the reader no matter which screen ran into it.
        onChallenge: (@Sendable (URL) -> Void)? = nil
    ) {
        self.transport = transport
        self.domain = domain
        self.retryPolicy = retryPolicy
        self.decoder = JSONDecoder()
        self.onChallenge = onChallenge
    }

    /// The mirror requests currently go to.
    public var currentDomain: DvachDomain { domain() }

    // MARK: Reading

    public func boards() async throws(DvachError) -> [Board] {
        try await get([Board].self, .boards)
    }

    public func catalog(board: String, byCreation: Bool = false) async throws(DvachError) -> CatalogResponse {
        try await get(
            CatalogResponse.self,
            byCreation ? .catalogByCreation(board: board) : .catalog(board: board)
        )
    }

    public func boardPage(board: String, page: Int) async throws(DvachError) -> BoardPage {
        try await get(BoardPage.self, .boardPage(board: board, page: page))
    }

    public func thread(board: String, num: Int) async throws(DvachError) -> ThreadResponse {
        try await get(ThreadResponse.self, .thread(board: board, thread: num))
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
        let reply = try await send(.thread(board: board, thread: num))
        do {
            return (try decoder.decode(ThreadResponse.self, from: reply.data), reply.data)
        } catch {
            throw DvachError.decoding(underlying: String(describing: error), url: reply.url)
        }
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

    public func threadInfo(board: String, thread: Int) async throws(DvachError) -> InfoResponse {
        try await get(
            InfoResponse.self,
            .threadInfo(board: board, thread: thread),
            envelope: \.error
        )
    }

    public func post(board: String, num: Int) async throws(DvachError) -> SinglePostResponse {
        try await get(SinglePostResponse.self, .post(board: board, num: num), envelope: \.error)
    }

    public func search(board: String, text: String) async throws(DvachError) -> SearchResponse {
        try await get(SearchResponse.self, .search(board: board, text: text), envelope: \.error)
    }

    /// One page of a board's archive. Page `0` is its index.
    public func archive(board: String, page: Int) async throws(DvachError) -> ArchiveResponse {
        try await get(
            ArchiveResponse.self,
            page <= 0 ? .archiveIndex(board: board) : .archivePage(board: board, page: page)
        )
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
        _ endpoint: DvachEndpoint,
        envelope: (@Sendable (T) -> DvachAPIError?)? = nil
    ) async throws(DvachError) -> T {
        let reply = try await send(endpoint)
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
    private func send(_ endpoint: DvachEndpoint) async throws(DvachError) -> HTTPReply {
        // The retry loop lives in a function with an untyped `throws`.
        //
        // Written with `throws(DvachError)` it crashed the app on any dropped
        // connection: a loop that awaits, catches and then leaves the scope
        // corrupts the task allocator ("freed pointer was not the last
        // allocation"). Converting the error at this boundary keeps the typed
        // error the callers rely on.
        do {
            return try await attemptSend(endpoint)
        } catch let error as DvachError {
            throw error
        } catch {
            throw DvachError.transport(underlying: error)
        }
    }

    private func attemptSend(_ endpoint: DvachEndpoint) async throws -> HTTPReply {
        let request = endpoint.request(on: domain())
        var lastError: DvachError?

        for (attempt, delay) in retryPolicy.backoff.enumerated() {
            if attempt > 0 {
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
                let url = reply.url ?? domain().baseURL
                onChallenge?(url)
                throw DvachError.cloudflareChallenge(url: url)
            }

            if reply.isSuccess { return reply }

            // The server's own errors arrive as a 200 with an envelope, so a 4xx
            // here is a genuine client error and will not change on a retry.
            guard reply.statusCode >= 500 || reply.statusCode == 429 else {
                throw DvachError.http(status: reply.statusCode, url: reply.url)
            }
            lastError = .http(status: reply.statusCode, url: reply.url)
        }

        throw lastError ?? .http(status: -1, url: nil)
    }
}
