import Foundation
import NeechanAPI

/// A browser engine that answers from canned replies and records what it was
/// asked to load and send.
///
/// Answers are taken in the order they were queued. Nothing queued is a
/// failure, so a test that did not expect a request finds out.
public actor FakeFourchanBrowser: FourchanBrowser {
    /// What the next captcha frame does.
    public enum FrameAnswer: Sendable {
        /// Posts this JSON back straight away.
        case reply(Data)
        /// Shows a browser check first, then posts this JSON back.
        case checkThenReply(Data)
        /// Shows a browser check and waits there until the request is cancelled.
        case checkAndWait
        case failure(FourchanBrowserError)
    }

    public struct Load: Sendable, Hashable {
        public let frame: URL
        public let page: URL
    }

    public struct Post: Sendable {
        public let request: URLRequest
        public let page: URL
    }

    private var frameAnswers: [FrameAnswer] = []
    private var postAnswers: [Result<HTTPReply, FourchanBrowserError>] = []
    public private(set) var loads: [Load] = []
    public private(set) var posts: [Post] = []

    public init() {}

    // MARK: Queueing

    public func queueFrame(_ answer: FrameAnswer) {
        frameAnswers.append(answer)
    }

    public func queueFrame(json: String) {
        frameAnswers.append(.reply(Data(json.utf8)))
    }

    public func queuePost(_ reply: HTTPReply) {
        postAnswers.append(.success(reply))
    }

    public func queuePostFailure(_ error: FourchanBrowserError) {
        postAnswers.append(.failure(error))
    }

    // MARK: FourchanBrowser

    public func captchaFrame(
        at frame: URL,
        inPage page: URL,
        onCheck: @escaping @Sendable () -> Void
    ) async throws(FourchanBrowserError) -> Data {
        loads.append(Load(frame: frame, page: page))
        guard !frameAnswers.isEmpty else { throw .failed("nothing queued for \(frame)") }
        switch frameAnswers.removeFirst() {
        case .reply(let data):
            return data
        case .checkThenReply(let data):
            onCheck()
            return data
        case .checkAndWait:
            onCheck()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw .cancelled
        case .failure(let error):
            throw error
        }
    }

    public func send(_ request: URLRequest, fromPage page: URL) async throws(FourchanBrowserError) -> HTTPReply {
        posts.append(Post(request: request, page: page))
        guard !postAnswers.isEmpty else { throw .failed("nothing queued for \(request.url?.absoluteString ?? "?")") }
        return try postAnswers.removeFirst().get()
    }
}
