import Foundation

/// Every request the app makes, as a value.
///
/// The cases are *intents*, not URLs: where each one lives is the adapter's
/// business, because the two sites lay their APIs out differently and one of
/// them does not serve several of these at all. Keeping the shaping here means
/// the client does not build strings, and the whole surface can be tested
/// without a network.
public enum ImageboardEndpoint: Sendable, Hashable {
    // Reading
    case boards
    /// Catalog ordered by most recent bump.
    case catalog(board: String)
    /// Catalog ordered by thread creation.
    case catalogByCreation(board: String)
    /// Paged board index.
    case boardPage(board: String, page: Int)
    case thread(board: String, thread: Int)
    /// Every thread on a board with its reply count, in one request.
    case boardThreads(board: String)
    /// Posts numbered `sinceNum` and above, for incremental refresh.
    case after(board: String, thread: Int, sinceNum: Int)
    /// Cheap poll returning only the thread's post count.
    case threadInfo(board: String, thread: Int)
    /// One post. `inThread` is a hint for a site with no single-post endpoint,
    /// which fetches the thread and picks the post out instead.
    case post(board: String, num: Int, inThread: Int? = nil)

    // Archive
    case archiveIndex(board: String)
    case archivePage(board: String, page: Int)
    case archiveThread(board: String, thread: Int)

    // Captcha
    case captchaSettings(board: String)
    case emojiCaptchaID(board: String, thread: Int?)
    case emojiCaptchaShow(id: String)
    case emojiCaptchaClick(id: String, emojiIndex: Int)
    /// 4chan's slider puzzle.
    case sliderCaptcha(board: String, thread: Int?)

    // Actions
    case search(board: String, text: String)
    case report(board: String, thread: Int, posts: [Int], comment: String)
    case passcodeLogin(passcode: String)
    case like(board: String, num: Int)
    case dislike(board: String, num: Int)

    /// The request to send.
    ///
    /// - Returns: nil when the selected site does not serve this endpoint.
    public func request(for selection: SiteSelection) -> URLRequest? {
        let adapter = selection.site.adapter
        guard let route = adapter.route(for: self, on: selection.endpoints) else { return nil }

        var components = URLComponents(url: route.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = route.path
        components.queryItems = route.queryItems

        var request = URLRequest(url: components.url ?? route.base)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if isPoll {
            // Nobody is waiting on these, and another one is along in a minute.
            // A poll left hanging on the default timeout holds a connection
            // open across several of its own successors.
            request.timeoutInterval = 15
        }

        if adapter.usesRevalidation(for: self) {
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
        case .threadInfo, .after, .boardThreads: true
        default: false
        }
    }

    var method: String {
        switch self {
        case .search, .emojiCaptchaClick, .report, .passcodeLogin: "POST"
        default: "GET"
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
}
