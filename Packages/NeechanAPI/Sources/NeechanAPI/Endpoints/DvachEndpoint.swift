import Foundation

/// Every 2ch request the app makes, as a value.
///
/// Keeping the URL and body construction here means the client does not build
/// strings, and the whole surface can be tested without a network.
public enum DvachEndpoint: Sendable, Hashable {
    // Reading
    case boards
    /// Catalog ordered by most recent bump.
    case catalog(board: String)
    /// Catalog ordered by thread creation.
    case catalogByCreation(board: String)
    /// Paged board index. Page `0` is `index.json`.
    case boardPage(board: String, page: Int)
    case thread(board: String, thread: Int)
    /// Posts numbered `sinceNum` and above, for incremental refresh.
    case after(board: String, thread: Int, sinceNum: Int)
    /// Cheap poll returning only the thread's post count.
    case threadInfo(board: String, thread: Int)
    case post(board: String, num: Int)

    // Archive
    case archiveIndex(board: String)
    case archivePage(board: String, page: Int)
    case archiveThread(board: String, thread: Int)

    // Captcha
    case captchaSettings(board: String)
    case emojiCaptchaID(board: String, thread: Int?)
    case emojiCaptchaShow(id: String)
    case emojiCaptchaClick(id: String, emojiIndex: Int)

    // Actions
    case search(board: String, text: String)
    case report(board: String, thread: Int, posts: [Int], comment: String)
    case passcodeLogin(passcode: String)
    case like(board: String, num: Int)
    case dislike(board: String, num: Int)

    /// The request to send, resolved against `domain`.
    public func request(on domain: DvachDomain) -> URLRequest {
        var components = URLComponents(url: domain.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = queryItems

        var request = URLRequest(url: components.url ?? domain.baseURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if isPoll {
            // Nobody is waiting on these, and another one is along in a minute.
            // A poll left hanging on the default timeout holds a connection
            // open across several of its own successors.
            request.timeoutInterval = 15
        }

        if usesRevalidation {
            // Asks the server to confirm rather than resend. It answers 304
            // where it can, and the session serves the body from its own cache;
            // where it sends no validators this costs nothing and changes
            // nothing.
            request.cachePolicy = .reloadRevalidatingCacheData
        }

        if let json = jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }

        if let form = multipartForm {
            var encoder = MultipartFormEncoder()
            for (name, value) in form {
                encoder.addField(name, value)
            }
            request.setValue(encoder.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = encoder.finalizedBody()
        }
        return request
    }

    // MARK: Shape

    /// Whether this is a request the app makes on a timer rather than because
    /// the reader asked for something.
    var isPoll: Bool {
        switch self {
        case .threadInfo, .after: true
        default: false
        }
    }

    /// Whether the same answer is likely to come back, and is worth confirming
    /// rather than re-sending.
    ///
    /// The polls, and the board listings: a board is opened, read and come back
    /// to, and its catalog is a long answer with every thumbnail's address in
    /// it. Separate from `isPoll` because that also shortens the timeout, which
    /// suits something nobody is waiting on and not a board the reader is
    /// looking at.
    var usesRevalidation: Bool {
        switch self {
        case .threadInfo, .after, .catalog, .catalogByCreation, .boardPage: true
        default: false
        }
    }

    var method: String {
        switch self {
        case .search, .emojiCaptchaClick, .report, .passcodeLogin: "POST"
        default: "GET"
        }
    }

    var path: String {
        switch self {
        case .boards:
            "/api/mobile/v2/boards"
        case .catalog(let board):
            "/\(escape(board))/catalog.json"
        case .catalogByCreation(let board):
            "/\(escape(board))/catalog_num.json"
        case .boardPage(let board, let page):
            page <= 0 ? "/\(escape(board))/index.json" : "/\(escape(board))/\(page).json"
        case .thread(let board, let thread):
            "/\(escape(board))/res/\(thread).json"
        case .after(let board, let thread, let sinceNum):
            "/api/mobile/v2/after/\(escape(board))/\(thread)/\(sinceNum)"
        case .threadInfo(let board, let thread):
            "/api/mobile/v2/info/\(escape(board))/\(thread)"
        case .post(let board, let num):
            "/api/mobile/v2/post/\(escape(board))/\(num)"
        case .archiveIndex(let board):
            "/\(escape(board))/arch/index.json"
        case .archivePage(let board, let page):
            "/\(escape(board))/arch/\(page).json"
        case .archiveThread(let board, let thread):
            "/\(escape(board))/arch/res/\(thread).json"
        case .captchaSettings(let board):
            "/api/captcha/settings/\(escape(board))"
        case .emojiCaptchaID:
            "/api/captcha/emoji/id"
        case .emojiCaptchaShow:
            "/api/captcha/emoji/show"
        case .emojiCaptchaClick:
            "/api/captcha/emoji/click"
        case .search:
            "/user/search"
        case .report:
            "/user/report"
        case .passcodeLogin:
            "/user/passlogin"
        case .like:
            "/api/like"
        case .dislike:
            "/api/dislike"
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
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

    /// Bodies the site expects as JSON rather than a form.
    var jsonBody: [String: Any]? {
        switch self {
        case .emojiCaptchaClick(let id, let emojiIndex):
            // The site names these in camel case here, unlike everywhere else.
            ["captchaTokenID": id, "emojiNumber": emojiIndex]
        default:
            nil
        }
    }

    var multipartForm: [(String, String)]? {
        switch self {
        case .search(let board, let text):
            [("board", board), ("text", text)]
        case .report(let board, let thread, let posts, let comment):
            [("board", board), ("thread", String(thread)), ("comment", comment)]
                // Repeating the name is how the site receives an array.
                + posts.map { ("post", String($0)) }
        case .passcodeLogin(let passcode):
            [("passcode", passcode)]
        default:
            nil
        }
    }

    /// Board codes come from user input (the drawer search box accepts any
    /// text), so they are escaped rather than trusted as path segments.
    private func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .dvachPathSegment) ?? ""
    }
}

extension CharacterSet {
    /// Unreserved characters plus the few 2ch actually uses in board codes.
    static let dvachPathSegment = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~"
    )
}
