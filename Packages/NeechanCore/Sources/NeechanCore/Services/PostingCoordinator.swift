import Foundation
import NeechanAPI
import SwiftData

/// Sends a post and deals with everything that follows.
///
/// Sending is not just an HTTP call: the staged files have to be processed, the
/// resulting post has to be remembered as the reader's own, and the draft has
/// to be cleared only once the site has actually accepted it.
public actor PostingCoordinator {
    /// How far sending has got.
    public enum Stage: Sendable, Equatable {
        case preparingFiles
        case solvingProofOfWork
        case uploading
        case done
    }

    private let postingService: PostingService
    private let drafts: DraftRepository
    private let ownPosts: OwnPostsRepository

    public init(
        postingService: PostingService,
        drafts: DraftRepository,
        ownPosts: OwnPostsRepository
    ) {
        self.postingService = postingService
        self.drafts = drafts
        self.ownPosts = ownPosts
    }

    /// Sends a draft.
    ///
    /// - Parameters:
    ///   - captchaToken: the solved emoji captcha, or nil when none is needed.
    ///   - proofOfWork: the challenge answer that accompanies the captcha.
    ///   - sliderAnswer: what the reader read off 4chan's slider puzzle, with
    ///     the token it was issued against. Solved by them, never by the app.
    ///   - deletionPassword: what lets them delete the post afterwards, on a
    ///     site that asks for one.
    ///   - onStage: progress, for the sending overlay.
    public func send(
        _ draft: DraftState,
        board: BoardRef,
        thread: Int?,
        captchaToken: String?,
        proofOfWork: Int?,
        sliderAnswer: (challenge: String, response: String)? = nil,
        usesPasscode: Bool = false,
        deletionPassword: String? = nil,
        onStage: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> PostingOutcome {
        onStage?(.preparingFiles)
        let attachments = try prepareAttachments(draft.attachments)

        let captcha: PostingRequest.Captcha
        if let sliderAnswer {
            captcha = .slider(challenge: sliderAnswer.challenge, response: sliderAnswer.response)
        } else if let captchaToken {
            captcha = .emoji(token: captchaToken, proofOfWork: proofOfWork)
        } else if usesPasscode {
            captcha = .passcode
        } else {
            captcha = .none
        }

        var request = PostingRequest(
            board: board.code,
            thread: thread,
            comment: draft.comment,
            captcha: captcha
        )
        request.subject = draft.subject.isEmpty ? nil : draft.subject
        request.name = draft.name.isEmpty ? nil : draft.name
        request.email = draft.email.isEmpty ? nil : draft.email
        request.tags = draft.tags.isEmpty ? nil : draft.tags
        request.icon = draft.icon
        request.isSage = draft.isSage
        request.isOriginalPoster = draft.isOriginalPoster
        request.attachments = attachments
        request.deletionPassword = deletionPassword

        onStage?(.uploading)
        let outcome = try await postingService.send(request)

        // Only now is the draft safe to clear: until the site answered, a
        // failure would have lost what the reader wrote.
        try? await drafts.discard(board: board, thread: thread)

        let threadNum = outcome.threadNum(repliedTo: thread)
        switch outcome {
        case .posted(let num):
            let key = ThreadKey(site: board.site, board: board.code, threadNum: threadNum)
            try? await ownPosts.record(key, postNum: num)
        case .threadCreated(let num):
            let key = ThreadKey(site: board.site, board: board.code, threadNum: num)
            try? await ownPosts.record(key, postNum: num)
        }

        onStage?(.done)
        return outcome
    }

    /// Reads each staged file and applies its options.
    private func prepareAttachments(
        _ staged: [DraftAttachmentState]
    ) throws -> [PostingRequest.Attachment] {
        try staged.map { attachment in
            let data = try DraftRepository.attachmentData(at: attachment.localRelativePath)
            let processed = AttachmentProcessor.process(
                data: data,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                options: attachment.processing
            )
            return PostingRequest.Attachment(
                fileName: processed.fileName,
                mimeType: processed.mimeType,
                data: processed.data
            )
        }
    }
}
