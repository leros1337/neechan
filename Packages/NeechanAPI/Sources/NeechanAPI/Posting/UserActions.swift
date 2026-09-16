import Foundation

/// Reporting a post to the moderators.
public struct ReportService: Sendable {
    private let client: DvachClient

    public init(client: DvachClient) {
        self.client = client
    }

    /// - Parameter posts: the posts being reported, which may be several.
    public func report(
        board: String,
        thread: Int,
        posts: [Int],
        comment: String
    ) async throws(DvachError) {
        _ = try await client.report(board: board, thread: thread, posts: posts, comment: comment)
    }
}

/// Voting, on the boards that allow it.
public struct LikeService: Sendable {
    private let client: DvachClient

    public init(client: DvachClient) {
        self.client = client
    }

    public func like(board: String, num: Int) async throws(DvachError) {
        _ = try await client.vote(board: board, num: num, isLike: true)
    }

    public func dislike(board: String, num: Int) async throws(DvachError) {
        _ = try await client.vote(board: board, num: num, isLike: false)
    }
}

/// A passcode session.
public struct PasscodeAuth: Sendable {
    /// What the site says about an active passcode.
    public struct Session: Sendable, Equatable {
        public let type: String
        public let expiresAt: Date?
    }

    private let client: DvachClient

    public init(client: DvachClient) {
        self.client = client
    }

    /// Exchanges the passcode for the cookie the site then recognises.
    ///
    /// The cookie is stored by the session's own jar; nothing else is needed to
    /// post with it afterwards.
    public func logIn(passcode: String) async throws(DvachError) -> Session {
        let response = try await client.passcodeLogin(passcode: passcode)
        guard let passcode = response.passcode else {
            throw DvachError.api(
                response.error
                    ?? DvachAPIError(
                        code: .passcodeMissing,
                        message: String(localized: "The passcode was not accepted.", bundle: .module, locale: AppLocale.current)
                    )
            )
        }
        return Session(
            type: passcode.type,
            expiresAt: passcode.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

/// `POST /user/report` and `GET /api/like`
public struct ActionResponse: Sendable, Decodable {
    public let result: Int
    public let error: DvachAPIError?
}

/// `POST /user/passlogin?json=1`
public struct PasscodeResponse: Sendable, Decodable {
    public struct Passcode: Sendable, Decodable {
        public let type: String
        public let expires: Int?
    }

    public let result: Int
    public let error: DvachAPIError?
    public let passcode: Passcode?
}
