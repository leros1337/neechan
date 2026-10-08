import Foundation

/// 4chan's captcha, as its frame hands it to the page that asked.
///
/// A few steps, each a prompt and a strip of pictures: the reader slides
/// through the pictures, stops on the one the prompt asks for and moves on.
/// Answering it is the reader's job and only the reader's — nothing in this app
/// looks at a picture, compares two of them or picks one, and nothing should.
///
/// The same object also carries everything the site says *instead* of a
/// puzzle: how long to wait before asking again, a longer wait with its own
/// message, a refusal, or a request for a further check first. Which of those
/// applies is decided in the order the site's own script reads them, which is
/// what `outcome` reproduces.
///
/// Undocumented: the shape is taken from the site's own `tcaptcha.min.js`.
public struct FourchanCaptcha: Sendable, Decodable, Hashable {
    /// One step: what to look for, and the pictures to look through.
    ///
    /// Not called `Task`, which would shadow Swift's own inside this type.
    public struct Step: Sendable, Hashable {
        /// The prompt as the site wrote it: HTML, usually its instructions
        /// with the picture it asks about inline.
        public let text: String?
        /// `text` read into words and pictures, once, when the reply arrives.
        public let prompt: FourchanCaptchaMarkup?
        /// Base64 PNG: the prompt as a picture, preferred over `text`.
        public let image: String?
        /// Base64 PNGs, in the order the slider passes through them.
        public let items: [String]

        public init(text: String?, image: String?, items: [String]) {
            self.text = text
            self.prompt = text.map(FourchanCaptchaMarkup.init(html:)).flatMap { $0.isEmpty ? nil : $0 }
            self.image = image
            self.items = items
        }
    }

    /// What to do with the ticket the site keeps between requests.
    public enum Ticket: Sendable, Hashable {
        case keep(String)
        /// The site sent `false`: the stored one is no good any more.
        case discard
    }

    /// What the reply amounts to, read in the site's own order.
    public enum Outcome: Sendable, Hashable {
        /// The April 2026 variant, served only to a page that asks for it.
        case extended
        /// A further check, from a third party, before any puzzle.
        case ticketCaptcha(siteKey: String?)
        /// No puzzle for a while yet; the button stays off until then.
        case waiting(seconds: Int, message: String?)
        /// Turned away, in the site's words.
        case refused(String)
        case steps(challenge: String, steps: [Step])
        /// Nothing to answer, though the challenge still goes back with the
        /// post, with an empty response beside it.
        case notRequired(challenge: String)
        case unreadable
    }

    /// The token that travels back with the answer as `t-challenge`.
    public let challenge: String?
    /// How long the token is good for, in seconds.
    public let ttl: Int?
    public let steps: [Step]
    public let ticket: Ticket?
    /// Seconds before the next request may be made. Sent with puzzles and
    /// refusals alike, and different from one reply to the next.
    public let cooldown: Int?
    public let needsTicketCaptcha: Bool
    public let siteKey: String?
    /// Seconds of a longer wait, during which no puzzle is served.
    public let ticketWait: Int?
    public let ticketWaitMessage: String?
    public let error: String?
    public let hasExtendedTask: Bool

    public var outcome: Outcome {
        // `_buildFromJson`: the extended variant first, then a further check,
        // then a wait, then a refusal, and only then a puzzle.
        if hasExtendedTask { return .extended }
        if needsTicketCaptcha { return .ticketCaptcha(siteKey: siteKey) }
        if let ticketWait, ticketWait > 0 {
            return .waiting(seconds: ticketWait, message: ticketWaitMessage)
        }
        if let error, !error.isEmpty { return .refused(error) }
        guard let challenge, !challenge.isEmpty else { return .unreadable }
        return steps.isEmpty
            ? .notRequired(challenge: challenge)
            : .steps(challenge: challenge, steps: steps)
    }

    enum CodingKeys: String, CodingKey {
        case challenge, ttl, ticket, error, sitekey, mpcd, pcd, extTask
        case tasks
        case cooldown = "cd"
        case ticketWaitMessage = "pcd_msg"
    }

    enum StepKeys: String, CodingKey {
        case str, img, items
    }

    /// Read field by field, tolerating what the wire actually carries.
    ///
    /// The endpoint is undocumented, and the models this app decodes elsewhere
    /// are deliberately total for the same reason: one field arriving as a
    /// number where a string was expected must not turn into "the site sent
    /// something this app could not read", which tells the reader nothing they
    /// can act on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        challenge = Self.string(container, .challenge)
        ttl = Self.int(container, .ttl)
        cooldown = Self.int(container, .cooldown)
        ticketWait = Self.int(container, .pcd)
        ticketWaitMessage = Self.string(container, .ticketWaitMessage)
        error = Self.string(container, .error)
        siteKey = Self.string(container, .sitekey)
        needsTicketCaptcha = Self.flag(container, .mpcd)
        hasExtendedTask = (try? container.decodeNil(forKey: .extTask)) == false

        if (try? container.decode(Bool.self, forKey: .ticket)) == false {
            ticket = .discard
        } else if let kept = Self.string(container, .ticket), !kept.isEmpty {
            ticket = .keep(kept)
        } else {
            ticket = nil
        }

        var steps: [Step] = []
        if var tasks = try? container.nestedUnkeyedContainer(forKey: .tasks) {
            while !tasks.isAtEnd {
                let position = tasks.currentIndex
                guard let task = try? tasks.nestedContainer(keyedBy: StepKeys.self) else {
                    // Step past whatever this was, so the rest still reads.
                    if (try? tasks.decodeNil()) != true { _ = try? tasks.decode(Discarded.self) }
                    // And give up rather than spin on something that will not move.
                    if tasks.currentIndex == position { break }
                    continue
                }
                let items = Self.strings(task, .items)
                // A step with nothing to slide through cannot be answered.
                guard !items.isEmpty else { continue }
                steps.append(
                    Step(
                        text: try? task.decodeIfPresent(String.self, forKey: .str),
                        image: (try? task.decodeIfPresent(String.self, forKey: .img)).flatMap {
                            $0.isEmpty ? nil : $0
                        },
                        items: items
                    )
                )
            }
        }
        self.steps = steps
    }

    public init(
        challenge: String? = nil,
        ttl: Int? = nil,
        steps: [Step] = [],
        ticket: Ticket? = nil,
        cooldown: Int? = nil,
        needsTicketCaptcha: Bool = false,
        siteKey: String? = nil,
        ticketWait: Int? = nil,
        ticketWaitMessage: String? = nil,
        error: String? = nil,
        hasExtendedTask: Bool = false
    ) {
        self.challenge = challenge
        self.ttl = ttl
        self.steps = steps
        self.ticket = ticket
        self.cooldown = cooldown
        self.needsTicketCaptcha = needsTicketCaptcha
        self.siteKey = siteKey
        self.ticketWait = ticketWait
        self.ticketWaitMessage = ticketWaitMessage
        self.error = error
        self.hasExtendedTask = hasExtendedTask
    }

    /// Anything at all, read only to move past it.
    private struct Discarded: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private static func string<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    private static func int<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        // A cooldown has been seen with a fractional part.
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text) ?? Double(text).map { Int($0.rounded()) }
        }
        return nil
    }

    /// The site's script only asks whether the field is truthy.
    private static func flag<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) -> Bool {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = int(container, key) { return value != 0 }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return !text.isEmpty }
        return false
    }

    /// The strings in an array, skipping anything that is not one.
    private static func strings<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) -> [String] {
        guard var list = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var values: [String] = []
        while !list.isAtEnd {
            let position = list.currentIndex
            if let value = try? list.decode(String.self) {
                if !value.isEmpty { values.append(value) }
            } else if (try? list.decodeNil()) != true {
                _ = try? list.decode(Discarded.self)
            }
            if list.currentIndex == position { break }
        }
        return values
    }
}
