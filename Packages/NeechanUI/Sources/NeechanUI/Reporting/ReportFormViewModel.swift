import Foundation
import NeechanAPI
import NeechanCore
import Observation
import SwiftUI

/// Drives the report form: the comment, and sending it.
///
/// Much smaller than ``ReplyFormViewModel`` because the site asks for much
/// less. 2ch's `POST /user/report` wants a board, a thread, the posts and a
/// comment, and no captcha at all — a report costs the reader nothing to make,
/// which is the point of one.
@MainActor
@Observable
public final class ReportFormViewModel {
    public enum SendState: Equatable {
        case idle
        case sending
        case sent
        case failed(message: String)
    }

    public let board: String
    /// The thread the reported post is in. The site files the report against
    /// it, so a report on the original post names the thread twice.
    public let thread: Int
    /// The post being reported. One at a time: the site accepts an array, but
    /// a menu item on a post is a statement about that post.
    public let postNum: Int

    public var comment = ""
    public private(set) var sendState: SendState = .idle

    private let services: AppServices

    public init(board: String, thread: Int, postNum: Int, services: AppServices) {
        self.board = board
        self.thread = thread
        self.postNum = postNum
        self.services = services
    }

    /// Empty is refused here rather than by the site.
    ///
    /// 2ch answers an empty comment with `-51 ErrorReportEmpty`, which is a
    /// round trip spent learning something the form already knows.
    public var canSend: Bool {
        guard case .sending = sendState else {
            return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    public func send() async {
        guard canSend else { return }
        sendState = .sending

        do {
            try await services.reports.report(
                board: board,
                thread: thread,
                posts: [postNum],
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            sendState = .sent
        } catch {
            // The site's own wording where there is any: it is the one that
            // knows this report was already sent, or that too many posts were
            // named. `readableMessage` prefers it and falls back to ours.
            sendState = .failed(message: error.readableMessage)
        }
    }
}
