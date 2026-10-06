import Foundation
import NeechanAPI
import NeechanAPITesting
@testable import NeechanCore
import NeechanSettings
import Testing
@testable import NeechanUI

/// Putting an edited picture in place of the file that was picked.
@Suite("Replacing an attachment", .serialized)
@MainActor
struct AttachmentReplaceTests {
    private let edited = ImageEditOutput(
        data: Data("edited".utf8),
        fileExtension: "jpg",
        mimeType: "image/jpeg",
        pixelSize: PixelSize(width: 1, height: 1)
    )

    /// A form whose staged files go to a folder of their own.
    private func withModel(
        _ body: (ReplyFormViewModel, AppServices, URL) async throws -> Void
    ) async throws {
        let directory = URL.temporaryDirectory.appending(path: "replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = AppSettings(defaults: UserDefaults(suiteName: "replace.\(UUID().uuidString)")!)
        settings.imageboard = .dvach
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let model = ReplyFormViewModel(board: "test", thread: 1, services: services)

        try await DraftRepository.$directoryOverride.withValue(directory) {
            try await body(model, services, directory)
        }
    }

    @Test("it keeps its place, its id and its options")
    func keepsPlace() async throws {
        try await withModel { model, _, _ in
            model.attach(data: Data("one".utf8), fileName: "one.png", mimeType: "image/png")
            model.attach(data: Data("two".utf8), fileName: "two.png", mimeType: "image/png")
            model.draft.attachments[1].processing.renameTo = "picture"
            model.draft.attachments[1].processing.appendsUniqueHash = true
            let before = model.draft.attachments[1]

            let replaced = try #require(await model.replaceAttachmentContents(before.id, with: edited))

            #expect(model.draft.attachments.map(\.id) == [model.draft.attachments[0].id, before.id])
            #expect(replaced.id == before.id)
            #expect(replaced.processing.renameTo == "picture")
            #expect(replaced.processing.appendsUniqueHash)
            #expect(model.draft.attachments[1] == replaced)
        }
    }

    @Test("it takes the new name, type and file, and forgets the old scale")
    func takesNewFile() async throws {
        try await withModel { model, _, _ in
            model.attach(data: Data("photo".utf8), fileName: "photo.heic", mimeType: "image/heic")
            model.draft.attachments[0].processing.scalePercent = 50
            let id = model.draft.attachments[0].id

            let replaced = try #require(await model.replaceAttachmentContents(id, with: edited))

            #expect(replaced.fileName == "photo.jpg")
            #expect(replaced.mimeType == "image/jpeg")
            #expect(replaced.processing.scalePercent == nil)
            #expect(try DraftRepository.attachmentData(at: replaced.localRelativePath) == Data("edited".utf8))
        }
    }

    @Test("the old file is deleted, and the saved draft points at the new one")
    func oldFileGoes() async throws {
        try await withModel { model, services, directory in
            model.attach(data: Data("photo".utf8), fileName: "photo.png", mimeType: "image/png")
            let before = model.draft.attachments[0]

            let replaced = try #require(await model.replaceAttachmentContents(before.id, with: edited))

            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: before.localRelativePath).path))
            let saved = try await services.drafts.draft(for: BoardRef(site: .dvach, code: "test"), thread: 1)
            #expect(saved.attachments.map(\.localRelativePath) == [replaced.localRelativePath])
        }
    }

    @Test("saving options from a sheet opened before the edit brings back neither the old file nor the old scale")
    func staleSheet() async throws {
        try await withModel { model, _, _ in
            model.attach(data: Data("photo".utf8), fileName: "photo.png", mimeType: "image/png")
            model.draft.attachments[0].processing.scalePercent = 50
            var sheetCopy = model.draft.attachments[0]

            let replaced = try #require(await model.replaceAttachmentContents(sheetCopy.id, with: edited))
            sheetCopy.processing.appendsUniqueHash = false
            sheetCopy.processing.renameTo = "renamed"
            model.updateAttachmentOptions(sheetCopy)

            let current = model.draft.attachments[0]
            #expect(current.localRelativePath == replaced.localRelativePath)
            #expect(current.fileName == "photo.jpg")
            #expect(current.processing.scalePercent == nil)
            #expect(!current.processing.appendsUniqueHash)
            #expect(current.processing.renameTo == "renamed")
        }
    }

    @Test("an attachment removed in the meantime stages nothing")
    func removedMeanwhile() async throws {
        try await withModel { model, _, directory in
            model.attach(data: Data("photo".utf8), fileName: "photo.png", mimeType: "image/png")
            let id = model.draft.attachments[0].id
            model.removeAttachment(id)
            let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path)

            #expect(await model.replaceAttachmentContents(id, with: edited) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == filesBefore)
            #expect(model.draft.attachments.isEmpty)
        }
    }
}
