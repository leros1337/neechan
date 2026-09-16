import Foundation
import NeechanAPI

/// A transport that answers from canned replies and records what it was asked.
///
/// Stubs are matched against the request URL's path (and query, when the stub
/// supplies one), most-recently-registered first, so a test can override a
/// general stub with a specific one.
public actor StubTransport: HTTPTransport {
    public struct Stub: Sendable {
        let matches: @Sendable (URLRequest) -> Bool
        let reply: @Sendable (URLRequest) throws -> HTTPReply
    }

    public enum StubError: Error, CustomStringConvertible {
        case noStub(url: String)

        public var description: String {
            switch self {
            case .noStub(let url): "StubTransport has no stub for \(url)"
            }
        }
    }

    private var stubs: [Stub] = []
    private(set) public var requests: [URLRequest] = []

    public init() {}

    // MARK: Registering

    /// Answers any request whose path ends with `pathSuffix`.
    public func stub(
        pathSuffix: String,
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = ["content-type": "application/json; charset=utf-8"]
    ) {
        stubs.append(
            Stub(
                matches: { $0.url?.path().hasSuffix(pathSuffix) ?? false },
                reply: { HTTPReply(data: data, statusCode: statusCode, headers: headers, url: $0.url) }
            )
        )
    }

    /// Answers the *next* matching request only, then falls through to whatever
    /// was registered before it. Use it to make the first attempt fail and the
    /// retry succeed.
    public func stubOnce(
        pathSuffix: String,
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = ["content-type": "application/json; charset=utf-8"]
    ) {
        let consumed = Consumed()
        stubs.append(
            Stub(
                matches: { request in
                    guard request.url?.path().hasSuffix(pathSuffix) ?? false else { return false }
                    return consumed.take()
                },
                reply: { HTTPReply(data: data, statusCode: statusCode, headers: headers, url: $0.url) }
            )
        )
    }

    /// Answers every request, whatever the URL.
    public func stubEverything(
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = ["content-type": "application/json; charset=utf-8"]
    ) {
        stubs.append(
            Stub(
                matches: { _ in true },
                reply: { HTTPReply(data: data, statusCode: statusCode, headers: headers, url: $0.url) }
            )
        )
    }

    /// Fails the next matching request, to drive retry and error paths.
    /// Answers any request whose path contains `fragment`.
    ///
    /// The incremental endpoint carries the board, thread and post number at
    /// the end of its path, so matching on a suffix means knowing all three;
    /// matching on a fragment does not.
    public func stub(
        pathContaining fragment: String,
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = ["content-type": "application/json; charset=utf-8"]
    ) {
        stubs.append(
            Stub(
                matches: { $0.url?.path().contains(fragment) ?? false },
                reply: { HTTPReply(data: data, statusCode: statusCode, headers: headers, url: $0.url) }
            )
        )
    }

    /// Fails the *next* matching request only, so the retry can succeed.
    public func stubOnce(pathSuffix: String, failingWith error: any Error) {
        let consumed = Consumed()
        stubs.append(
            Stub(
                matches: { request in
                    (request.url?.path().hasSuffix(pathSuffix) ?? false) && consumed.take()
                },
                reply: { _ in throw error }
            )
        )
    }

    public func stub(pathSuffix: String, failingWith error: any Error) {
        stubs.append(
            Stub(
                matches: { $0.url?.path().hasSuffix(pathSuffix) ?? false },
                reply: { _ in throw error }
            )
        )
    }

    /// Answers with a custom rule.
    public func stub(_ stub: Stub) {
        stubs.append(stub)
    }

    // MARK: Inspecting

    /// Requests seen so far, oldest first.
    public func recordedRequests() -> [URLRequest] { requests }

    /// The most recent request, if any.
    public func lastRequest() -> URLRequest? { requests.last }

    /// The URLs of every request, as absolute strings.
    public func requestedURLs() -> [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    public func reset() {
        stubs.removeAll()
        requests.removeAll()
    }

    // MARK: HTTPTransport

    /// One-shot latch for `stubOnce`. The matcher closures are `@Sendable` and
    /// run while the actor is already executing, so a reference box is enough.
    private final class Consumed: @unchecked Sendable {
        private var used = false
        func take() -> Bool {
            if used { return false }
            used = true
            return true
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        requests.append(request)
        for stub in stubs.reversed() where stub.matches(request) {
            return try stub.reply(request)
        }
        throw StubError.noStub(url: request.url?.absoluteString ?? "<no url>")
    }
}
