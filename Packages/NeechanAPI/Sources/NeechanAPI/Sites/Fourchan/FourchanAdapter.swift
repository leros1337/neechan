import Foundation

/// 4chan's URL shapes.
///
/// The read API is a tree of static JSON files on `a.4cdn.org`; the captcha and
/// posting live on `sys.4chan.org`. Everything 2ch offers beyond that —
/// incremental refresh, the count-only poll, search, voting, reports,
/// passcodes — has no counterpart here and routes to nil, which the client
/// turns into `DvachError.unsupported`. `SiteCapabilities.fourchan` is what
/// stops anything asking in the first place.
struct FourchanAdapter: SiteAdapter {
    let site = Imageboard.fourchan

    func route(for endpoint: ImageboardEndpoint, on endpoints: SiteEndpoints) -> SiteRoute? {
        let escape = escapeBoardCode
        switch endpoint {
        case .boards:
            return SiteRoute(base: endpoints.api, path: "/boards.json")
        // 4chan orders its catalog by bump and offers no other ordering;
        // `CatalogRepository` already sorts by creation date itself.
        case .catalog(let board), .catalogByCreation(let board):
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/catalog.json")
        case .boardPage(let board, let page):
            // Index pages start at 1: there is no `index.json`, and `/g/0.json`
            // is a 404.
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/\(max(1, page)).json")
        case .thread(let board, let thread):
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/thread/\(thread).json")
        case .boardThreads(let board):
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/threads.json")
        // The archive is one list of numbers for the whole board; the mapper
        // reverses and pages it.
        case .archiveIndex(let board), .archivePage(let board, _):
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/archive.json")
        // An archived thread is still served from the ordinary thread endpoint.
        case .archiveThread(let board, let thread):
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/thread/\(thread).json")
        // There is no single-post endpoint: the caller supplies the thread it
        // lives in and the mapper picks the post out.
        case .post(let board, _, let inThread):
            guard let inThread else { return nil }
            return SiteRoute(base: endpoints.api, path: "/\(escape(board))/thread/\(inThread).json")
        case .sliderCaptcha(let board, let thread):
            return SiteRoute(
                base: endpoints.posting,
                path: "/captcha",
                queryItems: [
                    URLQueryItem(name: "board", value: board),
                    thread.map { URLQueryItem(name: "thread_id", value: String($0)) },
                ].compactMap { $0 }
            )
        case .after, .threadInfo, .captchaSettings, .emojiCaptchaID, .emojiCaptchaShow,
             .emojiCaptchaClick, .search, .report, .passcodeLogin, .like, .dislike:
            return nil
        }
    }

    /// False, deliberately, and it is not an oversight.
    ///
    /// `a.4cdn.org` sends `cache-control: max-age=5, stale-while-revalidate=10`
    /// and an `ETag`. Left on the default policy, the session answers a repeat
    /// request inside five seconds from its own cache without going out at all,
    /// which is the rate limiting the site's own rules ask for, for free.
    /// Forcing revalidation would turn each of those into a conditional GET.
    /// 2ch sends no validators, which is why it is on there.
    func usesRevalidation(for endpoint: ImageboardEndpoint) -> Bool { false }
}

extension FourchanAdapter {
    /// 4chan's static files carry posts and nothing else, so the board's own
    /// details have to come from `/boards.json` and be held by the client.
    var needsBoardMetadata: Bool { true }

    func boards(from data: Data, decoder: JSONDecoder) throws -> [Board] {
        try FourchanMapping.boards(from: data, decoder: decoder)
    }

    func catalog(
        from data: Data, board: Board?, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> CatalogResponse {
        guard let board else { throw UnsupportedBySite(site: site) }
        return try FourchanMapping.catalog(
            from: data, board: board, endpoints: endpoints, decoder: decoder
        )
    }

    func boardPage(
        from data: Data, board: Board?, page: Int, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> BoardPage {
        guard let board else { throw UnsupportedBySite(site: site) }
        return try FourchanMapping.boardPage(
            from: data, board: board, page: page, endpoints: endpoints, decoder: decoder
        )
    }

    func thread(
        from data: Data, board: Board?, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> ThreadResponse {
        guard let board else { throw UnsupportedBySite(site: site) }
        return try FourchanMapping.thread(
            from: data, board: board, endpoints: endpoints, decoder: decoder
        )
    }

    /// There is no single-post endpoint: the request fetched the whole thread
    /// the post lives in, and the post is picked out of it here.
    func singlePost(
        from data: Data, board: Board?, num: Int, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> SinglePostResponse {
        let response = try thread(from: data, board: board, endpoints: endpoints, decoder: decoder)
        return SinglePostResponse(post: response.posts.first { $0.num == num })
    }

    func archive(
        from data: Data, board: String, page: Int, decoder: JSONDecoder
    ) throws -> ArchiveResponse {
        try FourchanMapping.archive(from: data, board: board, page: page, decoder: decoder)
    }

    func threadCounts(from data: Data, decoder: JSONDecoder) throws -> [Int: ThreadCount] {
        try FourchanMapping.threadCounts(from: data, decoder: decoder)
    }
}

extension FourchanAdapter {
    /// `POST https://sys.4chan.org/{board}/post`, as the site's own reply form
    /// sends it: different field names, a different arrangement and a different
    /// host from 2ch's.
    func postingRequest(_ request: PostingRequest, on endpoints: SiteEndpoints) -> URLRequest {
        var encoder = MultipartFormEncoder()
        for (name, value) in request.fourchanFormFields() {
            encoder.addField(name, value)
        }
        // One file, and it is `upfile`: 4chan takes no more than one per post.
        if let attachment = request.attachments.first {
            encoder.addFile(
                "upfile",
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: attachment.data
            )
        }

        var urlRequest = URLRequest(
            url: endpoints.posting.appending(path: "\(request.board)/post")
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(encoder.contentType, forHTTPHeaderField: "Content-Type")
        // The answer is a web page, not JSON.
        urlRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        urlRequest.setValue(
            endpoints.web.appending(path: "\(request.board)/").absoluteString,
            forHTTPHeaderField: "Referer"
        )
        urlRequest.httpBody = encoder.finalizedBody()
        urlRequest.timeoutInterval = 120
        return urlRequest
    }

    func postingOutcome(from reply: HTTPReply) throws(PostingError) -> PostingOutcome {
        try FourchanPostingReply.outcome(from: String(decoding: reply.data, as: UTF8.self))
    }
}
