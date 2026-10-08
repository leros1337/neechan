import Foundation
import NeechanAPI
import Observation

/// What 4chan's captcha has said that outlives one reply form.
///
/// The cooldowns are the server's, and they run whether or not the form is
/// open: closing it and opening it again must not offer a Get Captcha the site
/// will only refuse, nor forget a puzzle the reader was halfway through. One
/// per app, owned by the services, because the site counts per reader rather
/// than per thread.
@MainActor
@Observable
public final class FourchanCaptchaMemory {
    /// The longer wait the site can impose, with its own words.
    public struct TicketWait: Sendable, Hashable {
        public var message: String?
        public var endsAt: Date

        public init(message: String?, endsAt: Date) {
            self.message = message
            self.endsAt = endsAt
        }
    }

    /// A puzzle that was handed out and has not been sent yet.
    public struct Pending: Sendable, Hashable {
        public var board: String
        public var thread: Int?
        public var challenge: String
        public var progress: FourchanCaptchaProgress
        public var expiresAt: Date

        public init(
            board: String,
            thread: Int?,
            challenge: String,
            progress: FourchanCaptchaProgress,
            expiresAt: Date
        ) {
            self.board = board
            self.thread = thread
            self.challenge = challenge
            self.progress = progress
            self.expiresAt = expiresAt
        }
    }

    /// When Get Captcha may be pressed again, as the last reply said.
    public var reloadAvailableAt: Date?
    public var ticketWait: TicketWait?
    public var pending: Pending?

    public init() {}
}
