import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia
import Observation
import SwiftUI

/// Drives the reply form: the draft, the captcha and the send.
@MainActor
@Observable
public final class ReplyFormViewModel {
    public let board: String
    /// The thread being replied to; nil when creating one.
    public let thread: Int?
    /// Board rules, which decide which fields the form may show.
    public var boardInfo: Board?

    public var draft = DraftState()
    public var captcha: CaptchaState = .idle
    public var sendState: SendState = .idle
    /// Seconds left before the captcha token stops being accepted.
    public var captchaSecondsRemaining: Int?

    /// The keys the reader has already picked, in the order they picked them.
    ///
    /// The site never sends these back: each step replaces the whole keyboard,
    /// so a symbol picked two steps ago is gone from the screen. Keeping them
    /// here is the only way to show what has been answered so far, which the
    /// instruction "some appear only later" makes necessary.
    public private(set) var chosenCaptchaKeys: [PlatformImage] = []

    /// What the reader has picked in the comment field, bound to the editor so
    /// markup wraps their selection rather than landing after it.
    public var commentSelection: TextSelection? {
        didSet {
            if commentSelection != nil { rememberedCommentSelection = commentSelection }
        }
    }

    /// The last selection the editor reported.
    ///
    /// Reaching for a toolbar button can take focus off the field, and the
    /// editor clears its selection when that happens — which would leave the
    /// markup with nothing to wrap at the moment it is asked to wrap it.
    private var rememberedCommentSelection: TextSelection?

    public enum CaptchaState {
        case idle
        case loading
        /// A keyboard to answer, with the images already decoded.
        case challenge(image: PlatformImage?, keys: [PlatformImage?])
        case solved(token: String)
        /// The site waived it, for a passcode or because the board has it off.
        case notRequired
        case failed(String)

        var isSolvedOrWaived: Bool {
            switch self {
            case .solved, .notRequired: true
            default: false
            }
        }
    }

    public enum SendState: Equatable {
        case idle
        case sending(PostingCoordinator.Stage)
        case sent(PostingOutcome)
        case failed(message: String, needsNewCaptcha: Bool)
    }

    private let services: AppServices
    private var session: EmojiCaptchaSession?
    private var solvedToken: String?
    private var proofOfWork: Int?
    private var usesPasscode = false
    private var autosaveTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    public init(board: String, thread: Int?, services: AppServices) {
        self.board = board
        self.thread = thread
        self.services = services
    }

    // MARK: Lifecycle

    public func start() async {
        draft = (try? await services.drafts.draft(for: board, thread: thread)) ?? DraftState()
        boardInfo = try? await services.boards.board(id: board)
        await loadCaptcha()
    }

    /// Saves the draft a moment after typing stops, rather than on every keystroke.
    public func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = draft
        autosaveTask = Task { [weak self, board, thread, services] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            try? await services.drafts.save(snapshot, board: board, thread: thread)
            _ = self
        }
    }

    /// Saves immediately, for when the form closes.
    public func saveNow() async {
        autosaveTask?.cancel()
        try? await services.drafts.save(draft, board: board, thread: thread)
    }

    public func discardDraft() async {
        autosaveTask?.cancel()
        draft = DraftState()
        try? await services.drafts.discard(board: board, thread: thread)
    }

    // MARK: Captcha

    public func loadCaptcha() async {
        countdownTask?.cancel()
        captcha = .loading
        solvedToken = nil
        proofOfWork = nil
        chosenCaptchaKeys = []

        let session = services.makeCaptchaSession()
        self.session = session
        do {
            let state = try await session.start(board: board, thread: thread)
            await apply(state)
        } catch {
            captcha = .failed(String(describing: error))
        }
    }

    public func selectEmoji(at index: Int) async {
        guard let session else { return }

        // Remembered before the reply lands: applying it replaces the keyboard
        // this key came from.
        if case .challenge(_, let keys) = captcha, let chosen = keys[safe: index] ?? nil {
            chosenCaptchaKeys.append(chosen)
        }

        do {
            await apply(try await session.select(emojiAt: index))
        } catch {
            chosenCaptchaKeys = []
            captcha = .failed(String(describing: error))
        }
    }

    private func apply(_ state: EmojiCaptchaSession.State) async {
        switch state {
        case .challenge(let step):
            captcha = .challenge(
                image: Self.decode(step.image),
                keys: step.keyboard.map(Self.decode)
            )
            startCountdown()
            // The proof of work is solved while the reader picks emoji, so
            // sending does not then wait on it.
            if let session = self.session {
                Task { [weak self] in
                    let answer = await session.solveProofOfWork()
                    await MainActor.run { self?.proofOfWork = answer }
                }
            }

        case .solved(let token):
            solvedToken = token
            chosenCaptchaKeys = []
            captcha = .solved(token: token)
            if proofOfWork == nil {
                proofOfWork = await session?.solveProofOfWork()
            }

        case .notRequired(let reason):
            usesPasscode = reason == .passcode
            chosenCaptchaKeys = []
            captcha = .notRequired
            countdownTask?.cancel()
            captchaSecondsRemaining = nil
        }
    }

    /// Counts the captcha down and reloads it when it lapses, which is what the
    /// Dashchan fork does and what readers expect.
    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let expiresAt = await self?.session?.expiresAt else { return }
            while !Task.isCancelled {
                let remaining = Int(expiresAt.timeIntervalSinceNow.rounded())
                await MainActor.run { self?.captchaSecondsRemaining = max(0, remaining) }
                if remaining <= 0 {
                    await self?.loadCaptcha()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func decode(_ base64: String) -> PlatformImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return PlatformImage(data: data)
    }

    // MARK: Composing

    /// Wraps what the reader picked, or inserts empty markers at the cursor.
    public func applyMarkup(_ style: WakabaMarkup.Style) {
        let comment = draft.comment
        let range = selectedCommentRange ?? Range(uncheckedBounds: (commentCursor, commentCursor))
        let selected = String(comment[range])
        let start = comment.distance(from: comment.startIndex, to: range.lowerBound)

        draft.comment.replaceSubrange(range, with: WakabaMarkup.wrap(selected, in: style))

        // Where the reader is left: between empty markers so they can type, or
        // on their own text again, so a second style nests around it instead of
        // making them pick it out a second time.
        let inner = start + style.markers.opening.count
        let opening = commentIndex(atOffset: inner)
        commentSelection = selected.isEmpty
            ? TextSelection(insertionPoint: opening)
            : TextSelection(range: opening..<commentIndex(atOffset: inner + selected.count))
        scheduleAutosave()
    }

    /// The text the reader picked, when the comment still has such a range.
    private var selectedCommentRange: Range<String.Index>? {
        guard let selection = commentSelection ?? rememberedCommentSelection else { return nil }
        let range: Range<String.Index>
        switch selection.indices {
        case .selection(let picked):
            range = picked
        case .multiSelection(let picked):
            // One pair of markers around the whole span: a post has no way to
            // express markup that skips the gaps between several selections.
            guard let first = picked.ranges.first, let last = picked.ranges.last else { return nil }
            range = first.lowerBound..<last.upperBound
        @unknown default:
            return nil
        }
        // A remembered selection can outlive the edit it was made in, and an
        // index past the end of the comment would trap rather than simply miss.
        guard !range.isEmpty, range.upperBound <= draft.comment.endIndex else { return nil }
        return range
    }

    /// Where an insertion goes when nothing is picked: the cursor, or the end
    /// of the comment when the field has not been in use.
    private var commentCursor: String.Index {
        guard let selection = commentSelection ?? rememberedCommentSelection,
              case .selection(let range) = selection.indices,
              range.upperBound <= draft.comment.endIndex
        else { return draft.comment.endIndex }
        return range.lowerBound
    }

    private func commentIndex(atOffset offset: Int) -> String.Index {
        draft.comment.index(
            draft.comment.startIndex,
            offsetBy: offset,
            limitedBy: draft.comment.endIndex
        ) ?? draft.comment.endIndex
    }

    public func insertQuote(of postNum: Int, text: String? = nil) {
        if let text, !text.isEmpty {
            draft.comment += WakabaMarkup.quotePost(num: postNum, text: text)
        } else {
            draft.comment += WakabaMarkup.replyLink(to: postNum)
        }
        scheduleAutosave()
    }

    // MARK: Attachments

    /// Stages a picked file for upload.
    public func attach(data: Data, fileName: String, mimeType: String) {
        guard draft.attachments.count < maxAttachments else { return }
        guard let path = try? DraftRepository.stageAttachment(data: data, fileName: fileName) else {
            return
        }
        draft.attachments.append(
            DraftAttachmentState(
                fileName: fileName,
                localRelativePath: path,
                mimeType: mimeType,
                processing: services.settings.newAttachmentProcessing()
            )
        )
        scheduleAutosave()
    }

    public func removeAttachment(_ id: UUID) {
        draft.attachments.removeAll { $0.id == id }
        scheduleAutosave()
    }

    public func updateAttachment(_ attachment: DraftAttachmentState) {
        guard let index = draft.attachments.firstIndex(where: { $0.id == attachment.id }) else {
            return
        }
        draft.attachments[index] = attachment
        scheduleAutosave()
    }

    /// Four files, or eight with a passcode, matching the site's own limits.
    public var maxAttachments: Int {
        usesPasscode ? 8 : 4
    }

    // MARK: Sending

    public var canSend: Bool {
        guard case .sending = sendState else {
            return !draft.isEmpty && captcha.isSolvedOrWaived && withinCommentLimit
        }
        return false
    }

    public var commentLimit: Int {
        boardInfo?.maxComment ?? 15000
    }

    public var withinCommentLimit: Bool {
        draft.comment.count <= commentLimit
    }

    public func send() async {
        guard canSend else { return }
        sendState = .sending(.preparingFiles)

        do {
            let outcome = try await services.posting.send(
                draft,
                board: board,
                thread: thread,
                captchaToken: solvedToken,
                proofOfWork: proofOfWork,
                usesPasscode: usesPasscode,
                onStage: { [weak self] stage in
                    Task { @MainActor in self?.sendState = .sending(stage) }
                }
            )
            draft = DraftState()
            services.settings.recordPostSent()
            sendState = .sent(outcome)
        } catch let error as PostingError {
            sendState = .failed(message: error.message, needsNewCaptcha: error.requiresNewCaptcha)
            if error.requiresNewCaptcha {
                await loadCaptcha()
            }
        } catch {
            sendState = .failed(message: String(describing: error), needsNewCaptcha: true)
            await loadCaptcha()
        }
    }
}


extension Array {
    /// The element at `index`, or nil when it is out of range.
    ///
    /// The keyboard and the tap that answers it come from different turns, so
    /// an index can outlive the array it was for.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
