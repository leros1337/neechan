import CoreGraphics
import Foundation
import ImageIO
import NeechanAPI
import NeechanAPITesting
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Attachment processor")
struct AttachmentProcessorTests {
    private func samplePNG() throws -> Data {
        try FixtureLoader.data(.sampleStillPNG)
    }

    @Test("with no options the file is passed through untouched")
    func passthrough() throws {
        let data = try samplePNG()
        let output = AttachmentProcessor.process(
            data: data, fileName: "a.png", mimeType: "image/png", options: .none
        )
        #expect(output.data == data)
        #expect(output.fileName == "a.png")
        #expect(output.mimeType == "image/png")
    }

    @Test("a unique hash changes the bytes so the site sees a new file")
    func uniqueHashChangesContent() throws {
        let data = try samplePNG()
        let output = AttachmentProcessor.process(
            data: data, fileName: "a.png", mimeType: "image/png",
            options: AttachmentProcessing(appendsUniqueHash: true)
        )
        #expect(output.data != data)
        #expect(output.data.count > data.count)
        // The original bytes are intact, so the image still decodes.
        #expect(output.data.prefix(data.count) == data)
    }

    @Test("two files processed the same way still differ from each other")
    func uniqueHashIsRandom() throws {
        let data = try samplePNG()
        let options = AttachmentProcessing(appendsUniqueHash: true)
        let first = AttachmentProcessor.process(
            data: data, fileName: "a.png", mimeType: "image/png", options: options
        )
        let second = AttachmentProcessor.process(
            data: data, fileName: "a.png", mimeType: "image/png", options: options
        )
        #expect(first.data != second.data)
    }

    @Test("stripping metadata leaves a decodable image")
    func stripKeepsImage() throws {
        let output = AttachmentProcessor.process(
            data: try samplePNG(), fileName: "a.png", mimeType: "image/png",
            options: AttachmentProcessing(stripsMetadata: true)
        )
        #expect(output.data.isEmpty == false)
        #expect(EXIFReaderProbe.decodes(output.data))
    }

    @Test("re-encoding produces a JPEG and renames the file to match")
    func reencodeProducesJPEG() throws {
        let output = AttachmentProcessor.process(
            data: try samplePNG(), fileName: "a.png", mimeType: "image/png",
            options: AttachmentProcessing(reencodeQuality: 70)
        )
        #expect(output.mimeType == "image/jpeg")
        #expect(output.fileName == "a.jpg")
        #expect(EXIFReaderProbe.decodes(output.data))
    }

    @Test("scaling down reduces the pixel dimensions")
    func scaleReducesSize() throws {
        // A 4x4 fixture cannot show a scale change, so a larger one is built.
        let large = try ImageFactory.png(width: 200, height: 100)
        let output = AttachmentProcessor.process(
            data: large, fileName: "a.png", mimeType: "image/png",
            options: AttachmentProcessing(reencodeQuality: 80, scalePercent: 50)
        )
        let size = try #require(EXIFReaderProbe.pixelSize(of: output.data))
        #expect(size.width <= 100)
        #expect(size.width > 1)
    }

    @Test("renaming keeps the extension")
    func renameKeepsExtension() throws {
        let output = AttachmentProcessor.process(
            data: try samplePNG(), fileName: "личное.png", mimeType: "image/png",
            options: AttachmentProcessing(renameTo: "image")
        )
        #expect(output.fileName == "image.png")
    }

    @Test("renaming after a re-encode uses the new extension")
    func renameAfterReencode() throws {
        let output = AttachmentProcessor.process(
            data: try samplePNG(), fileName: "личное.png", mimeType: "image/png",
            options: AttachmentProcessing(reencodeQuality: 60, renameTo: "image")
        )
        #expect(output.fileName == "image.jpg")
    }

    @Test("a file that is not an image is left alone rather than corrupted")
    func nonImageIsUntouched() {
        let data = Data("not an image".utf8)
        let output = AttachmentProcessor.process(
            data: data, fileName: "a.webm", mimeType: "video/webm",
            options: AttachmentProcessing(stripsMetadata: true, reencodeQuality: 50)
        )
        #expect(output.data == data)
        #expect(output.fileName == "a.webm")
    }
}

@Suite("Draft repository")
struct DraftRepositoryTests {
    private func makeRepository() throws -> DraftRepository {
        DraftRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    @Test("a draft round-trips")
    func roundTrip() async throws {
        let repository = try makeRepository()
        var draft = DraftState()
        draft.comment = "черновик"
        draft.subject = "Тема"
        draft.isSage = true
        try await repository.save(draft, board: "test", thread: 1)

        let loaded = try await repository.draft(for: "test", thread: 1)
        #expect(loaded.comment == "черновик")
        #expect(loaded.subject == "Тема")
        #expect(loaded.isSage)
    }

    @Test("drafts are kept separately per board and thread")
    func separatePerThread() async throws {
        let repository = try makeRepository()
        try await repository.save(DraftState(comment: "один"), board: "test", thread: 1)
        try await repository.save(DraftState(comment: "два"), board: "test", thread: 2)
        try await repository.save(DraftState(comment: "новый"), board: "test", thread: nil)

        #expect(try await repository.draft(for: "test", thread: 1).comment == "один")
        #expect(try await repository.draft(for: "test", thread: 2).comment == "два")
        // A new thread is keyed as thread zero.
        #expect(try await repository.draft(for: "test", thread: nil).comment == "новый")
    }

    @Test("an unknown draft comes back empty rather than missing")
    func unknownDraftIsEmpty() async throws {
        let draft = try await makeRepository().draft(for: "test", thread: 999)
        #expect(draft.isEmpty)
    }

    @Test("emptying a draft deletes it")
    func emptyingDeletes() async throws {
        let repository = try makeRepository()
        try await repository.save(DraftState(comment: "что-то"), board: "test", thread: 1)
        try await repository.save(DraftState(comment: "   "), board: "test", thread: 1)

        #expect(try await repository.allDrafts().isEmpty)
    }

    @Test("saving twice updates rather than duplicating")
    func saveIsIdempotent() async throws {
        let repository = try makeRepository()
        try await repository.save(DraftState(comment: "раз"), board: "test", thread: 1)
        try await repository.save(DraftState(comment: "два"), board: "test", thread: 1)

        let all = try await repository.allDrafts()
        #expect(all.count == 1)
        #expect(try await repository.draft(for: "test", thread: 1).comment == "два")
    }

    @Test("attachments keep their order and their options")
    func attachmentsRoundTrip() async throws {
        let repository = try makeRepository()
        let draft = DraftState(
            comment: "с файлами",
            attachments: [
                DraftAttachmentState(
                    fileName: "a.png", localRelativePath: "a", mimeType: "image/png",
                    processing: AttachmentProcessing(appendsUniqueHash: true, stripsMetadata: true)
                ),
                DraftAttachmentState(
                    fileName: "b.webm", localRelativePath: "b", mimeType: "video/webm",
                    isSpoiler: true
                ),
            ]
        )
        try await repository.save(draft, board: "test", thread: 1)

        let loaded = try await repository.draft(for: "test", thread: 1)
        #expect(loaded.attachments.map(\.fileName) == ["a.png", "b.webm"])
        #expect(loaded.attachments[0].processing.appendsUniqueHash)
        #expect(loaded.attachments[0].processing.stripsMetadata)
        #expect(loaded.attachments[1].isSpoiler)
    }

    @Test("discarding removes the draft")
    func discard() async throws {
        let repository = try makeRepository()
        try await repository.save(DraftState(comment: "х"), board: "test", thread: 1)
        try await repository.discard(board: "test", thread: 1)
        #expect(try await repository.draft(for: "test", thread: 1).isEmpty)
    }
}

@Suite("Own posts")
struct OwnPostsRepositoryTests {
    private func makeRepository() throws -> OwnPostsRepository {
        OwnPostsRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    @Test("a recorded post is reported as the reader's own")
    func recordsPost() async throws {
        let repository = try makeRepository()
        try await repository.record(board: "test", threadNum: 1, postNum: 10)

        #expect(try await repository.isOwned(board: "test", postNum: 10))
        #expect(try await repository.postNums(board: "test", threadNum: 1) == [10])
    }

    @Test("recording the same post twice is harmless")
    func recordIsIdempotent() async throws {
        let repository = try makeRepository()
        try await repository.record(board: "test", threadNum: 1, postNum: 10)
        try await repository.record(board: "test", threadNum: 1, postNum: 10)
        #expect(try await repository.postNums(board: "test", threadNum: 1).count == 1)
    }

    @Test("the reader can mark and unmark a post by hand")
    func manualToggle() async throws {
        let repository = try makeRepository()
        try await repository.setOwned(true, board: "test", threadNum: 1, postNum: 7)
        #expect(try await repository.isOwned(board: "test", postNum: 7))

        try await repository.setOwned(false, board: "test", threadNum: 1, postNum: 7)
        #expect(try await repository.isOwned(board: "test", postNum: 7) == false)
    }

    @Test("posts are scoped to their board")
    func scopedToBoard() async throws {
        let repository = try makeRepository()
        try await repository.record(board: "test", threadNum: 1, postNum: 10)
        #expect(try await repository.isOwned(board: "b", postNum: 10) == false)
    }
}

@Suite("Posting coordinator")
struct PostingCoordinatorTests {
    private func makeCoordinator(
        _ transport: StubTransport
    ) throws -> (PostingCoordinator, DraftRepository, OwnPostsRepository) {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let client = DvachClient(transport: transport, domain: { .org })
        let drafts = DraftRepository(modelContainer: container)
        let ownPosts = OwnPostsRepository(modelContainer: container)
        let coordinator = PostingCoordinator(
            postingService: PostingService(client: client, transport: transport, domain: { .org }),
            drafts: drafts,
            ownPosts: ownPosts
        )
        return (coordinator, drafts, ownPosts)
    }

    @Test("a sent reply is remembered as the reader's own post")
    func recordsOwnPost() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))
        let (coordinator, _, ownPosts) = try makeCoordinator(transport)

        let outcome = try await coordinator.send(
            DraftState(comment: "привет"),
            board: "test", thread: 4242,
            captchaToken: "token", proofOfWork: 1
        )
        guard case .posted(let num) = outcome else {
            Issue.record("expected a posted reply")
            return
        }
        #expect(try await ownPosts.isOwned(board: "test", postNum: num))
        #expect(try await ownPosts.postNums(board: "test", threadNum: 4242).contains(num))
    }

    @Test("a created thread records its opening post as the reader's own")
    func recordsOwnThread() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingThreadOK))
        let (coordinator, _, ownPosts) = try makeCoordinator(transport)

        let outcome = try await coordinator.send(
            DraftState(comment: "новый тред"),
            board: "test", thread: nil,
            captchaToken: "token", proofOfWork: 1
        )
        guard case .threadCreated(let num) = outcome else {
            Issue.record("expected a new thread")
            return
        }
        #expect(try await ownPosts.postNums(board: "test", threadNum: num) == [num])
    }

    @Test("the draft is cleared once the post is accepted")
    func clearsDraftOnSuccess() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))
        let (coordinator, drafts, _) = try makeCoordinator(transport)

        try await drafts.save(DraftState(comment: "привет"), board: "test", thread: 4242)
        _ = try await coordinator.send(
            DraftState(comment: "привет"),
            board: "test", thread: 4242,
            captchaToken: "token", proofOfWork: 1
        )
        #expect(try await drafts.draft(for: "test", thread: 4242).isEmpty)
    }

    @Test("a refused post keeps the draft, so nothing the reader wrote is lost")
    func keepsDraftOnFailure() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingErrorCaptcha)
        )
        let (coordinator, drafts, ownPosts) = try makeCoordinator(transport)
        try await drafts.save(DraftState(comment: "важное"), board: "test", thread: 4242)

        await #expect(throws: PostingError.self) {
            _ = try await coordinator.send(
                DraftState(comment: "важное"),
                board: "test", thread: 4242,
                captchaToken: "stale", proofOfWork: 1
            )
        }
        #expect(try await drafts.draft(for: "test", thread: 4242).comment == "важное")
        #expect(try await ownPosts.postNums(board: "test", threadNum: 4242).isEmpty)
    }

    @Test("progress is reported so the overlay can explain the wait")
    func reportsProgress() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))
        let (coordinator, _, _) = try makeCoordinator(transport)

        let stages = StageRecorder()
        _ = try await coordinator.send(
            DraftState(comment: "привет"),
            board: "test", thread: 1,
            captchaToken: "token", proofOfWork: 1,
            onStage: { stages.record($0) }
        )
        #expect(stages.recorded.contains(.preparingFiles))
        #expect(stages.recorded.contains(.uploading))
        #expect(stages.recorded.last == .done)
    }
}

/// Collects the stages the coordinator reports.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [PostingCoordinator.Stage] = []

    func record(_ stage: PostingCoordinator.Stage) {
        lock.lock()
        defer { lock.unlock() }
        stages.append(stage)
    }

    var recorded: [PostingCoordinator.Stage] {
        lock.lock()
        defer { lock.unlock() }
        return stages
    }
}

/// Small image helpers, so the processing tests do not need extra fixtures.
private enum ImageFactory {
    static func png(width: Int, height: Int) throws -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try #require(context?.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// Reads back what the processor produced, without depending on NeechanMedia.
private enum EXIFReaderProbe {
    static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }
}

/// What a newly attached file starts with.
@MainActor
@Suite("Attachment defaults")
struct AttachmentDefaultsTests {
    private func makeSettings() throws -> AppSettings {
        AppSettings(defaults: try #require(UserDefaults(suiteName: "attach.\(UUID().uuidString)")))
    }

    @Test("a fresh install cleans every attachment")
    func defaults() throws {
        let processing = try makeSettings().newAttachmentProcessing()

        #expect(processing.appendsUniqueHash)
        #expect(processing.stripsMetadata)
        #expect(processing.renameTo != nil)
    }

    /// Two files attached to one post would collide on a shared name.
    @Test("each attachment gets its own name")
    func namesAreNotShared() throws {
        let settings = try makeSettings()

        let first = settings.newAttachmentProcessing().renameTo
        let second = settings.newAttachmentProcessing().renameTo

        #expect(first != nil)
        #expect(first != second)
    }

    @Test("turning renaming off keeps the original name")
    func renamingCanBeTurnedOff() throws {
        let settings = try makeSettings()
        settings.removesFileNamesByDefault = false

        #expect(settings.newAttachmentProcessing().renameTo == nil)
    }

    /// The rename replaces the stem only, so the site still sees a .jpg.
    @Test("a renamed file keeps its extension")
    func renameKeepsTheExtension() throws {
        let settings = try makeSettings()
        let processing = try #require(settings.newAttachmentProcessing().renameTo)

        let result = AttachmentProcessor.process(
            data: Data("x".utf8),
            fileName: "IMG_4471.jpg",
            mimeType: "image/jpeg",
            options: AttachmentProcessing(renameTo: processing)
        )
        #expect(result.fileName == "\(processing).jpg")
    }
}
