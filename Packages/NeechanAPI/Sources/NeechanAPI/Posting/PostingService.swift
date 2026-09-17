import Foundation

/// Sends posts.
///
/// Separate from `DvachClient` because posting must never be retried: a request
/// that timed out may still have been accepted, and a retry would double-post.
public actor PostingService {
    private let client: DvachClient
    private let transport: any HTTPTransport
    private let site: SiteProvider

    public init(client: DvachClient, transport: any HTTPTransport, site: @escaping SiteProvider) {
        self.client = client
        self.transport = transport
        self.site = site
    }

    /// Sends the post and reports what the site did with it.
    ///
    /// Which request to build and how to read the answer are the site's own
    /// business — one answers in JSON and the other in HTML — so both go
    /// through the adapter. What stays here is the part that must not vary:
    /// this is sent once and never retried, because a request that timed out
    /// may still have been accepted and a second attempt would double-post.
    public func send(_ request: PostingRequest) async throws -> PostingOutcome {
        let selection = site()
        let urlRequest = selection.site.adapter.postingRequest(
            request, on: selection.endpoints
        )

        let reply: HTTPReply
        do {
            reply = try await transport.send(urlRequest)
        } catch {
            throw PostingError(
                code: .unknown(0),
                message: String(
                    localized: "The post could not be sent.",
                    bundle: .module,
                    locale: AppLocale.current
                )
            )
        }

        // A browser check reaches the reader rather than being read as a
        // refusal to post: the post was never seen by the site at all.
        if ChallengeDetector.isChallenge(reply) {
            throw PostingError(
                code: .unknown(reply.statusCode),
                message: String(
                    localized: "The site wants to check your browser before accepting a post.",
                    bundle: .module,
                    locale: AppLocale.current
                )
            )
        }

        return try selection.site.adapter.postingOutcome(from: reply)
    }
}

/// `POST /user/posting`
struct PostingReply: Decodable {
    let result: Int?
    let num: Int?
    let thread: Int?
    let error: DvachAPIError?
}
