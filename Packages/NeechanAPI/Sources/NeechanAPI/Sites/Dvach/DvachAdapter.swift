import Foundation

/// 2ch's URL shapes.
///
/// Lifted unchanged out of the old `DvachEndpoint`, so the URLs this builds are
/// byte-for-byte the ones the app has always sent.
struct DvachAdapter: SiteAdapter {
    let site = Imageboard.dvach

    func route(for endpoint: ImageboardEndpoint, on endpoints: SiteEndpoints) -> SiteRoute? {
        guard let path = path(for: endpoint) else { return nil }
        return SiteRoute(base: endpoints.api, path: path, queryItems: queryItems(for: endpoint))
    }

    /// The polls, and the board listings: a board is opened, read and come back
    /// to, and its catalog is a long answer with every thumbnail's address in
    /// it. Separate from `isPoll` because that also shortens the timeout, which
    /// suits something nobody is waiting on and not a board the reader is
    /// looking at.
    func usesRevalidation(for endpoint: ImageboardEndpoint) -> Bool {
        switch endpoint {
        case .threadInfo, .after, .catalog, .catalogByCreation, .boardPage: true
        default: false
        }
    }

    /// Every 2ch answer carries the board object inside it.
    let needsBoardMetadata = false

    // The neutral models *are* 2ch's shapes, so every one of these is the plain
    // decode the client used to do itself.

    func boards(from data: Data, decoder: JSONDecoder) throws -> [Board] {
        try decoder.decode([Board].self, from: data)
    }

    func catalog(
        from data: Data, board: Board?, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> CatalogResponse {
        try decoder.decode(CatalogResponse.self, from: data)
    }

    func boardPage(
        from data: Data, board: Board?, page: Int, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> BoardPage {
        try decoder.decode(BoardPage.self, from: data)
    }

    func thread(
        from data: Data, board: Board?, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> ThreadResponse {
        try decoder.decode(ThreadResponse.self, from: data)
    }

    func singlePost(
        from data: Data, board: Board?, num: Int, endpoints: SiteEndpoints, decoder: JSONDecoder
    ) throws -> SinglePostResponse {
        try decoder.decode(SinglePostResponse.self, from: data)
    }

    func archive(
        from data: Data, board: String, page: Int, decoder: JSONDecoder
    ) throws -> ArchiveResponse {
        try decoder.decode(ArchiveResponse.self, from: data)
    }

    /// 2ch has a count-only poll of its own, so nothing asks this of it.
    func threadCounts(from data: Data, decoder: JSONDecoder) throws -> [Int: ThreadCount] {
        throw UnsupportedBySite(site: site)
    }

    private func path(for endpoint: ImageboardEndpoint) -> String? {
        let escape = escapeBoardCode
        switch endpoint {
        case .boards:
            return "/api/mobile/v2/boards"
        case .catalog(let board):
            return "/\(escape(board))/catalog.json"
        case .catalogByCreation(let board):
            return "/\(escape(board))/catalog_num.json"
        case .boardPage(let board, let page):
            return page <= 0 ? "/\(escape(board))/index.json" : "/\(escape(board))/\(page).json"
        case .thread(let board, let thread):
            return "/\(escape(board))/res/\(thread).json"
        case .after(let board, let thread, let sinceNum):
            return "/api/mobile/v2/after/\(escape(board))/\(thread)/\(sinceNum)"
        case .threadInfo(let board, let thread):
            return "/api/mobile/v2/info/\(escape(board))/\(thread)"
        case .post(let board, let num, _):
            return "/api/mobile/v2/post/\(escape(board))/\(num)"
        case .archiveIndex(let board):
            return "/\(escape(board))/arch/index.json"
        case .archivePage(let board, let page):
            return "/\(escape(board))/arch/\(page).json"
        case .archiveThread(let board, let thread):
            return "/\(escape(board))/arch/res/\(thread).json"
        case .captchaSettings(let board):
            return "/api/captcha/settings/\(escape(board))"
        case .emojiCaptchaID:
            return "/api/captcha/emoji/id"
        case .emojiCaptchaShow:
            return "/api/captcha/emoji/show"
        case .emojiCaptchaClick:
            return "/api/captcha/emoji/click"
        case .search:
            return "/user/search"
        case .report:
            return "/user/report"
        case .passcodeLogin:
            return "/user/passlogin"
        case .like:
            return "/api/like"
        case .dislike:
            return "/api/dislike"
        // 4chan's only, and 2ch has no counterpart.
        case .boardThreads, .sliderCaptcha:
            return nil
        }
    }

    private func queryItems(for endpoint: ImageboardEndpoint) -> [URLQueryItem]? {
        switch endpoint {
        case .search, .passcodeLogin:
            // The site answers with HTML unless it is told the caller wants JSON.
            [URLQueryItem(name: "json", value: "1")]
        case .like(let board, let num), .dislike(let board, let num):
            [URLQueryItem(name: "board", value: board), URLQueryItem(name: "num", value: String(num))]
        case .emojiCaptchaID(let board, let thread):
            [
                URLQueryItem(name: "board", value: board),
                thread.map { URLQueryItem(name: "thread", value: String($0)) },
            ].compactMap { $0 }
        case .emojiCaptchaShow(let id):
            [URLQueryItem(name: "id", value: id)]
        default:
            nil
        }
    }
}

extension DvachAdapter {
    func postingRequest(_ request: PostingRequest, on endpoints: SiteEndpoints) -> URLRequest {
        var encoder = MultipartFormEncoder()
        for (name, value) in request.formFields() {
            encoder.addField(name, value)
        }
        for attachment in request.attachments {
            // Repeating the name is how the site receives several files.
            encoder.addFile(
                "file[]",
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: attachment.data
            )
        }

        var urlRequest = URLRequest(
            url: endpoints.posting.appending(path: "user/posting")
                .appending(queryItems: [URLQueryItem(name: "nc", value: "1")])
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(encoder.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(endpoints.web.absoluteString, forHTTPHeaderField: "Referer")
        urlRequest.httpBody = encoder.finalizedBody()
        // Uploading a video over a slow connection takes a while; the default
        // would give up on a post that is still being accepted.
        urlRequest.timeoutInterval = 120
        return urlRequest
    }

    func postingOutcome(from reply: HTTPReply) throws(PostingError) -> PostingOutcome {
        guard let response = try? JSONDecoder().decode(PostingReply.self, from: reply.data) else {
            throw PostingError(
                code: .unknown(reply.statusCode),
                message: String(
                    localized: "The site answered with something unexpected.",
                    bundle: .module,
                    locale: AppLocale.current
                )
            )
        }
        if let error = response.error, error.code != .none {
            throw PostingError(error)
        }
        if let thread = response.thread, thread > 0 { return .threadCreated(num: thread) }
        if let num = response.num, num > 0 { return .posted(num: num) }
        throw PostingError(
            code: .unknown(reply.statusCode),
            message: String(
                localized: "The site did not say whether the post was made.",
                bundle: .module,
                locale: AppLocale.current
            )
        )
    }
}
