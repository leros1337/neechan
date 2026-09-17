import Foundation

/// Where one endpoint lives on one site.
public struct SiteRoute: Sendable, Hashable {
    /// Which of the site's hosts serves it.
    public let base: URL
    /// Already percent-encoded.
    public let path: String
    public let queryItems: [URLQueryItem]?

    public init(base: URL, path: String, queryItems: [URLQueryItem]? = nil) {
        self.base = base
        self.path = path
        self.queryItems = queryItems
    }
}

/// The per-site half of building a request.
///
/// A `Sendable` value rather than an actor, and deliberately not a client
/// protocol: `DvachClient`'s retry loop carries two workarounds for a Swift
/// runtime allocator crash, and a second implementation of it would be a second
/// copy of those. One actor sends; an adapter says what to send where.
protocol SiteAdapter: Sendable {
    var site: Imageboard { get }

    /// - Returns: nil when the site does not serve this endpoint at all.
    func route(for endpoint: ImageboardEndpoint, on endpoints: SiteEndpoints) -> SiteRoute?

    /// Whether the same answer is likely to come back and is worth confirming
    /// rather than re-sending.
    func usesRevalidation(for endpoint: ImageboardEndpoint) -> Bool

    /// Whether a catalog or thread answer arrives without the board's own
    /// details, so the client has to have fetched them separately.
    ///
    /// 2ch puts the whole board object in every response; 4chan's static files
    /// carry nothing but posts.
    var needsBoardMetadata: Bool { get }

    // MARK: Decoding
    //
    // Concrete rather than generic, so the client can hold `any SiteAdapter`.

    func boards(from data: Data, decoder: JSONDecoder) throws -> [Board]

    func catalog(
        from data: Data, board: Board?, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> CatalogResponse

    func boardPage(
        from data: Data, board: Board?, page: Int, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> BoardPage

    func thread(
        from data: Data, board: Board?, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> ThreadResponse

    func singlePost(
        from data: Data, board: Board?, num: Int, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> SinglePostResponse

    func archive(
        from data: Data, board: String, page: Int, decoder: JSONDecoder
    ) throws -> ArchiveResponse

    func threadCounts(from data: Data, decoder: JSONDecoder) throws -> [Int: ThreadCount]

    // MARK: Posting

    /// The request that sends one post. Deliberately built here rather than
    /// from `ImageboardEndpoint`: the two sites agree on nothing but multipart.
    func postingRequest(
        _ request: PostingRequest, on endpoints: SiteEndpoints
    ) -> URLRequest

    /// What the site said about it.
    func postingOutcome(from reply: HTTPReply) throws(PostingError) -> PostingOutcome
}

/// What an adapter reports when it is handed something its site never sends.
struct UnsupportedBySite: Error {
    let site: Imageboard
}

extension Imageboard {
    /// The adapter that knows this site's shapes.
    var adapter: any SiteAdapter {
        switch self {
        case .dvach: DvachAdapter()
        case .fourchan: FourchanAdapter()
        }
    }
}

/// Board codes come from user input (the drawer search box accepts any text),
/// so they are escaped rather than trusted as path segments.
func escapeBoardCode(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: .boardPathSegment) ?? ""
}

extension CharacterSet {
    /// Unreserved characters plus the few either site uses in board codes.
    static let boardPathSegment = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~"
    )
}
