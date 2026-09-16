import Foundation

/// Sends posts.
///
/// Separate from `DvachClient` because posting must never be retried: a request
/// that timed out may still have been accepted, and a retry would double-post.
public actor PostingService {
    private let client: DvachClient
    private let transport: any HTTPTransport
    private let domain: DomainProvider

    public init(client: DvachClient, transport: any HTTPTransport, domain: @escaping DomainProvider) {
        self.client = client
        self.transport = transport
        self.domain = domain
    }

    /// Sends the post and reports what the site did with it.
    public func send(_ request: PostingRequest) async throws -> PostingOutcome {
        var encoder = MultipartFormEncoder()
        for (name, value) in request.formFields() {
            encoder.addField(name, value)
        }
        for attachment in request.attachments {
            encoder.addFile(
                "file[]",
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: attachment.data
            )
        }

        var urlRequest = URLRequest(
            url: domain().baseURL.appending(path: "user/posting")
                .appending(queryItems: [URLQueryItem(name: "nc", value: "1")])
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(encoder.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(domain().baseURL.absoluteString, forHTTPHeaderField: "Referer")
        urlRequest.httpBody = encoder.finalizedBody()
        // Uploading a video over a slow connection takes a while; the default
        // would give up on a post that is still being accepted.
        urlRequest.timeoutInterval = 120

        let reply: HTTPReply
        do {
            reply = try await transport.send(urlRequest)
        } catch {
            throw PostingError(
                code: .unknown(0),
                message: String(localized: "The post could not be sent.", bundle: .module, locale: AppLocale.current)
            )
        }

        guard let response = try? JSONDecoder().decode(PostingReply.self, from: reply.data) else {
            throw PostingError(
                code: .unknown(reply.statusCode),
                message: String(
                    localized: "The site answered with something unexpected.", bundle: .module
                )
            )
        }

        if let error = response.error, error.code != .none {
            throw PostingError(error)
        }
        if let thread = response.thread, thread > 0 {
            return .threadCreated(num: thread)
        }
        if let num = response.num, num > 0 {
            return .posted(num: num)
        }
        throw PostingError(
            code: .unknown(reply.statusCode),
            message: String(localized: "The site did not say whether the post was made.", bundle: .module, locale: AppLocale.current)
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
