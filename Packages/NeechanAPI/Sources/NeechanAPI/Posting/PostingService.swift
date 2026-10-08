import Foundation

/// Sends posts.
///
/// Separate from `DvachClient` because posting must never be retried: a request
/// that timed out may still have been accepted, and a retry would double-post.
public actor PostingService {
    private let client: DvachClient
    private let transport: any HTTPTransport
    private let site: SiteProvider
    /// The browser engine, for a site whose posting host answers nothing else.
    private let browser: FourchanBrowserSlot?

    public init(
        client: DvachClient,
        transport: any HTTPTransport,
        site: @escaping SiteProvider,
        browser: FourchanBrowserSlot? = nil
    ) {
        self.client = client
        self.transport = transport
        self.site = site
        self.browser = browser
    }

    /// Sends the post and reports what the site did with it.
    ///
    /// Which request to build and how to read the answer are the site's own
    /// business — one answers in JSON and the other in HTML — so both go
    /// through the adapter, as does whether it has to leave from a page in
    /// the browser engine. What stays here is the part that must not vary:
    /// this is sent once and never retried, because a request that timed out
    /// may still have been accepted and a second attempt would double-post.
    public func send(_ request: PostingRequest) async throws -> PostingOutcome {
        let selection = site()
        let adapter = selection.site.adapter
        let urlRequest = adapter.postingRequest(request, on: selection.endpoints)

        let reply: HTTPReply
        if let page = adapter.browserPostingPage(for: request, on: selection.endpoints) {
            reply = try await sendThroughBrowser(urlRequest, from: page)
        } else {
            do {
                reply = try await transport.send(urlRequest)
            } catch {
                throw Self.notSent
            }
        }

        // A browser check reaches the reader rather than being read as a
        // refusal to post: the post was never seen by the site at all.
        if ChallengeDetector.isChallenge(reply) {
            throw PostingError(
                code: .unknown(reply.statusCode),
                message: String(
                    localized: "The site wants to check your browser before accepting a post.",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }

        return try adapter.postingOutcome(from: reply)
    }

    private func sendThroughBrowser(
        _ request: URLRequest,
        from page: URL
    ) async throws(PostingError) -> HTTPReply {
        guard let browser = browser?.current else {
            throw PostingError(
                code: .unknown(0),
                message: String(
                    localized: "Posting to this site needs the app's browser engine, which is not available here.",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }
        do {
            return try await browser.send(request, fromPage: page)
        } catch {
            guard case .unconfirmed = error else { throw Self.notSent }
            // It left and nothing readable came back. That is not the same as
            // not being sent, and saying it was would invite a double post.
            throw PostingError(
                code: .unknown(0),
                message: String(
                    localized: "The post may have gone through. Check the thread before sending it again.",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }
    }

    private static var notSent: PostingError {
        PostingError(
            code: .unknown(0),
            message: String(
                localized: "The post could not be sent.",
                bundle: .module.forAppLanguage(),
                locale: AppLocale.current
            )
        )
    }
}

/// `POST /user/posting`
struct PostingReply: Decodable {
    let result: Int?
    let num: Int?
    let thread: Int?
    let error: DvachAPIError?
}
