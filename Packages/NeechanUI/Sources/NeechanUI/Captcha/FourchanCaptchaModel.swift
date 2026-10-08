import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia
import Observation
import os

/// 4chan's captcha, in the reply form.
///
/// It behaves the way the site's own widget does, because the site holds the
/// reader to that: a captcha is asked for when the reader presses Get Captcha
/// and at no other time, every reply carries a cooldown before the next one may
/// be asked for, and an answer is spent by any attempt to post. Every one of
/// those numbers is the server's — this keeps deadlines, and decides nothing
/// about how long anything takes.
///
/// The puzzle itself is answered by the reader. The slider starts on the
/// instructions, Next stays off until they move it, and nothing here moves it
/// for them, looks at a picture or suggests one.
@MainActor
@Observable
public final class FourchanCaptchaModel {
    public enum Phase: Equatable {
        /// Nothing asked for yet, or the last one spent.
        case idle
        case loading
        /// The frame is showing a browser check, which the reader answers in
        /// the browser engine's own view.
        case checking
        case steps(FourchanCaptchaProgress)
        /// Every step answered: "Done."
        case answered
        /// A challenge with nothing to answer.
        case notRequired
        case expired
        /// Turned away, in the site's words.
        case refused(String)
        /// A further check, from hCaptcha, before any puzzle.
        case ticketCaptcha(siteKey: String)
        case failed(String)
    }

    public let board: String
    public let thread: Int?
    public private(set) var phase: Phase = .idle
    /// The time as of the last tick: what every countdown is measured from.
    public private(set) var now: Date

    private let service: FourchanCaptchaService
    private let memory: FourchanCaptchaMemory
    private let services: AppServices
    private let clock: @MainActor () -> Date

    private var challenge: String?
    /// The reader's picks, once every step is answered.
    private var response: String?
    private var expiresAt: Date?
    /// Which request is current. One that has been replaced must not come
    /// back and overwrite what its replacement got.
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    /// Pictures already decoded, keyed by what they were decoded from.
    @ObservationIgnored private var pictures: [String: PlatformImage] = [:]

    private static let log = Logger(subsystem: Signposts.subsystem, category: "fourchan-captcha")

    public init(
        board: String,
        thread: Int?,
        services: AppServices,
        clock: @escaping @MainActor () -> Date = { .now }
    ) {
        self.board = board
        self.thread = thread
        self.services = services
        self.service = services.fourchanCaptcha
        self.memory = services.fourchanCaptchaMemory
        self.clock = clock
        self.now = clock()
    }

    // MARK: Opening

    /// Picks up where an earlier form left this thread's captcha. Asks the
    /// site for nothing.
    public func prepare() {
        now = clock()
        guard case .idle = phase else { return }
        guard let pending = memory.pending,
              pending.board == board,
              pending.thread == thread,
              pending.expiresAt > now
        else { return }
        challenge = pending.challenge
        expiresAt = pending.expiresAt
        if pending.progress.steps.isEmpty {
            phase = .notRequired
        } else if pending.progress.isDone {
            response = pending.progress.response
            phase = .answered
        } else {
            phase = .steps(pending.progress)
        }
    }

    // MARK: Asking

    /// Whether Get Captcha may be pressed now.
    ///
    /// Always during a check: the reader may give up on it and ask again, and
    /// the site has set no cooldown yet because it has not answered.
    public var canRequest: Bool {
        switch phase {
        case .loading: return false
        case .checking: return true
        default:
            guard let available = memory.reloadAvailableAt else { return true }
            return now >= available
        }
    }

    /// Whole seconds until Get Captcha comes back, rounded up as the site's
    /// button counts them; nil when it is available.
    public var secondsUntilRequest: Int? {
        guard let available = memory.reloadAvailableAt else { return nil }
        let seconds = Int(available.timeIntervalSince(now).rounded(.up))
        return seconds > 0 ? seconds : nil
    }

    /// Whole seconds the current challenge has left, while there is one.
    public var secondsUntilExpiry: Int? {
        guard let expiresAt, challenge != nil else { return nil }
        switch phase {
        case .steps, .answered, .notRequired:
            return max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        default:
            return nil
        }
    }

    /// The longer wait's message while it runs, and the site's all-clear once
    /// it has.
    public var notice: String? {
        guard let wait = memory.ticketWait else { return nil }
        if now < wait.endsAt {
            return wait.message ?? String(localized: "Please wait a while.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
        }
        return String(localized: "You can now request a captcha.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
    }

    public func requestCaptcha() async {
        now = clock()
        guard canRequest else { return }
        await load(ticketResponse: nil)
    }

    /// The token from the further check, sent straight back as the site does,
    /// whatever the button says.
    public func ticketCaptchaAnswered(_ token: String) async {
        now = clock()
        await load(ticketResponse: token)
    }

    /// Stops waiting on a request the reader has walked away from.
    public func cancel() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        if phase == .loading || phase == .checking {
            phase = .idle
        }
    }

    private func load(ticketResponse: String?) async {
        loadTask?.cancel()
        generation += 1
        let mine = generation
        phase = .loading
        challenge = nil
        response = nil
        expiresAt = nil
        memory.pending = nil

        let request = FourchanCaptchaRequest(
            board: board,
            thread: thread,
            ticket: services.settings.fourchanCaptchaTicket,
            ticketResponse: ticketResponse
        )
        let service = self.service
        let task = Task { [weak self] in
            let result: Result<FourchanCaptcha, FourchanBrowserError>
            do throws(FourchanBrowserError) {
                result = .success(
                    try await service.captcha(request) {
                        Task { @MainActor in self?.checkShown(for: mine) }
                    }
                )
            } catch {
                result = .failure(error)
            }
            self?.finish(result, for: mine)
        }
        loadTask = task
        await task.value
    }

    private func checkShown(for request: Int) {
        guard request == generation, phase == .loading else { return }
        Self.log.notice("the frame is showing a browser check")
        phase = .checking
    }

    private func finish(_ result: Result<FourchanCaptcha, FourchanBrowserError>, for request: Int) {
        // A request that was replaced or abandoned says nothing about now.
        guard request == generation else { return }
        loadTask = nil
        now = clock()
        switch result {
        case .success(let captcha):
            apply(captcha)
        case .failure(.cancelled):
            if phase == .loading || phase == .checking { phase = .idle }
        case .failure(let error):
            phase = .failed(message(for: error))
        }
    }

    /// In the order the site's own script applies a reply.
    private func apply(_ captcha: FourchanCaptcha) {
        switch captcha.ticket {
        case .keep(let ticket): services.settings.fourchanCaptchaTicket = ticket
        case .discard: services.settings.fourchanCaptchaTicket = nil
        case nil: break
        }

        memory.reloadAvailableAt = captcha.cooldown.flatMap { $0 > 0 ? now.addingTimeInterval(TimeInterval($0)) : nil }
        memory.ticketWait = nil

        switch captcha.outcome {
        case .extended:
            phase = .failed(
                String(localized: "4chan sent a kind of captcha this app cannot show yet.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
            )

        case .ticketCaptcha(let siteKey):
            if let siteKey, !siteKey.isEmpty {
                phase = .ticketCaptcha(siteKey: siteKey)
            } else {
                phase = .failed(String(localized: "The captcha could not be read.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current))
            }

        case .waiting(let seconds, let message):
            let endsAt = now.addingTimeInterval(TimeInterval(seconds))
            memory.ticketWait = .init(message: message, endsAt: endsAt)
            // The site puts this on the button in place of the cooldown.
            memory.reloadAvailableAt = endsAt
            phase = .idle

        case .refused(let message):
            phase = .refused(message)

        case .steps(let challenge, let steps):
            start(challenge: challenge, progress: FourchanCaptchaProgress(steps: steps), ttl: captcha.ttl)
            phase = .steps(FourchanCaptchaProgress(steps: steps))

        case .notRequired(let challenge):
            start(challenge: challenge, progress: FourchanCaptchaProgress(steps: []), ttl: captcha.ttl)
            phase = .notRequired

        case .unreadable:
            phase = .failed(String(localized: "The captcha could not be read.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current))
        }
    }

    private func start(challenge: String, progress: FourchanCaptchaProgress, ttl: Int?) {
        self.challenge = challenge
        // Three seconds early, as the site's script expires it, so an answer
        // is not sent in the last moment the site would still have taken it.
        expiresAt = ttl.map { now.addingTimeInterval(TimeInterval($0 - 3)) }
        if let expiresAt {
            memory.pending = .init(
                board: board, thread: thread, challenge: challenge, progress: progress, expiresAt: expiresAt
            )
        }
    }

    private func message(for error: FourchanBrowserError) -> String {
        switch error {
        case .unavailable:
            String(localized: "Posting to 4chan needs the app's browser engine, which is not available here.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
        case .timedOut:
            String(localized: "The captcha did not arrive. Try again.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
        case .cancelled:
            String(localized: "The captcha did not arrive. Try again.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
        case .unconfirmed(let reason), .failed(let reason):
            reason
        }
    }

    // MARK: Answering

    /// The reader's slider, and nothing else, calls this.
    public func select(_ value: Int) {
        guard case .steps(var progress) = phase else { return }
        progress.select(value)
        phase = .steps(progress)
        memory.pending?.progress = progress
    }

    public func next() {
        guard case .steps(var progress) = phase, progress.canAdvance else { return }
        progress.next()
        if progress.isDone {
            response = progress.response
            phase = .answered
        } else {
            phase = .steps(progress)
        }
        memory.pending?.progress = progress
    }

    /// What goes with the post, while there is something to send and time to
    /// send it in.
    public var answer: (challenge: String, response: String)? {
        guard let challenge else { return nil }
        if let expiresAt, now >= expiresAt { return nil }
        switch phase {
        case .answered:
            return response.map { (challenge, $0) }
        case .notRequired:
            return (challenge, "")
        default:
            return nil
        }
    }

    /// After any attempt to post: the site takes the challenge whatever it
    /// made of the post, so this one is gone. The cooldown is the site's and
    /// stays.
    public func consume() {
        guard phase != .loading, phase != .checking else { return }
        challenge = nil
        response = nil
        expiresAt = nil
        memory.pending = nil
        phase = .idle
    }

    // MARK: Time

    /// Moves the clock on and lets lapse whatever has.
    public func tick() {
        now = clock()
        if let expiresAt, now >= expiresAt {
            switch phase {
            case .steps, .answered, .notRequired:
                Self.log.notice("captcha expired")
                challenge = nil
                response = nil
                self.expiresAt = nil
                memory.pending = nil
                phase = .expired
            default:
                break
            }
        }
    }

    // MARK: Pictures

    /// A step's picture, decoded once.
    func picture(_ base64: String) -> PlatformImage? {
        if let decoded = pictures[base64] { return decoded }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = PlatformImage(data: data)
        else { return nil }
        pictures[base64] = image
        return image
    }
}
