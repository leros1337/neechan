import Foundation
import SwiftData

/// An unsent post, as a value the view can hold.
public struct DraftState: Sendable, Equatable {
    public var comment: String
    public var subject: String
    public var name: String
    public var email: String
    public var tags: String
    public var icon: Int?
    public var isSage: Bool
    public var isOriginalPoster: Bool
    public var attachments: [DraftAttachmentState]

    public init(
        comment: String = "",
        subject: String = "",
        name: String = "",
        email: String = "",
        tags: String = "",
        icon: Int? = nil,
        isSage: Bool = false,
        isOriginalPoster: Bool = false,
        attachments: [DraftAttachmentState] = []
    ) {
        self.comment = comment
        self.subject = subject
        self.name = name
        self.email = email
        self.tags = tags
        self.icon = icon
        self.isSage = isSage
        self.isOriginalPoster = isOriginalPoster
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subject.isEmpty && attachments.isEmpty
    }
}

/// A staged file, as a value.
public struct DraftAttachmentState: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fileName: String
    public var localRelativePath: String
    public var mimeType: String
    public var processing: AttachmentProcessing
    public var isSpoiler: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        localRelativePath: String,
        mimeType: String,
        processing: AttachmentProcessing = .none,
        isSpoiler: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.localRelativePath = localRelativePath
        self.mimeType = mimeType
        self.processing = processing
        self.isSpoiler = isSpoiler
    }
}

/// Keeps unsent posts.
@ModelActor
public actor DraftRepository {
    /// Where staged files live, relative to Application Support.
    public static let attachmentsDirectoryName = "Drafts"

    /// The draft for a board and thread, or an empty one.
    public func draft(for board: String, thread: Int?) throws -> DraftState {
        guard let stored = try storedDraft(board: board, threadNum: thread ?? 0) else {
            return DraftState()
        }
        return DraftState(stored)
    }

    /// Saves the draft, or deletes it once there is nothing left in it.
    public func save(_ state: DraftState, board: String, thread: Int?) throws {
        let threadNum = thread ?? 0

        guard !state.isEmpty else {
            try discard(board: board, thread: thread)
            return
        }

        let draft = try storedDraft(board: board, threadNum: threadNum)
            ?? {
                let new = Draft(board: board, threadNum: threadNum)
                modelContext.insert(new)
                return new
            }()

        draft.comment = state.comment
        draft.subject = state.subject
        draft.name = state.name
        draft.email = state.email
        draft.tags = state.tags
        draft.icon = state.icon
        draft.isSage = state.isSage
        draft.isOriginalPoster = state.isOriginalPoster
        draft.updatedAt = .now

        // Attachments are replaced wholesale: they are few, and reconciling
        // them one by one would be more code than it saves.
        for existing in draft.attachments {
            modelContext.delete(existing)
        }
        draft.attachments = state.attachments.enumerated().map { index, attachment in
            let model = DraftAttachment(
                fileName: attachment.fileName,
                localRelativePath: attachment.localRelativePath,
                mimeType: attachment.mimeType,
                order: index
            )
            model.id = attachment.id
            model.appendsUniqueHash = attachment.processing.appendsUniqueHash
            model.stripsMetadata = attachment.processing.stripsMetadata
            model.reencodeQuality = attachment.processing.reencodeQuality
            model.scalePercent = attachment.processing.scalePercent
            model.renameTo = attachment.processing.renameTo
            model.isSpoiler = attachment.isSpoiler
            model.draft = draft
            return model
        }

        try modelContext.save()
    }

    /// Removes the draft and the files it staged.
    public func discard(board: String, thread: Int?) throws {
        guard let stored = try storedDraft(board: board, threadNum: thread ?? 0) else { return }

        for attachment in stored.attachments {
            let url = Self.attachmentsDirectory.appending(path: attachment.localRelativePath)
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(stored)
        try modelContext.save()
    }

    /// Every draft with something in it, most recent first.
    public func allDrafts() throws -> [(board: String, thread: Int, updatedAt: Date)] {
        let descriptor = FetchDescriptor<Draft>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
            .map { ($0.board, $0.threadNum, $0.updatedAt) }
    }

    /// Stores a file for a draft and returns its relative path.
    public nonisolated static func stageAttachment(
        data: Data,
        fileName: String
    ) throws -> String {
        let directory = attachmentsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let relative = "\(UUID().uuidString)-\(DownloadNaming.sanitise(fileName))"
        try data.write(to: directory.appending(path: relative), options: .atomic)
        return relative
    }

    public nonisolated static func attachmentData(at relativePath: String) throws -> Data {
        try Data(contentsOf: attachmentsDirectory.appending(path: relativePath))
    }

    nonisolated static var attachmentsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: attachmentsDirectoryName)
    }

    private func storedDraft(board: String, threadNum: Int) throws -> Draft? {
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate { $0.board == board && $0.threadNum == threadNum }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension DraftState {
    init(_ draft: Draft) {
        self.init(
            comment: draft.comment,
            subject: draft.subject,
            name: draft.name,
            email: draft.email,
            tags: draft.tags,
            icon: draft.icon,
            isSage: draft.isSage,
            isOriginalPoster: draft.isOriginalPoster,
            attachments: draft.attachments
                .sorted { $0.order < $1.order }
                .map(DraftAttachmentState.init)
        )
    }
}

extension DraftAttachmentState {
    init(_ model: DraftAttachment) {
        self.init(
            id: model.id,
            fileName: model.fileName,
            localRelativePath: model.localRelativePath,
            mimeType: model.mimeType,
            processing: AttachmentProcessing(
                appendsUniqueHash: model.appendsUniqueHash,
                stripsMetadata: model.stripsMetadata,
                reencodeQuality: model.reencodeQuality,
                scalePercent: model.scalePercent,
                renameTo: model.renameTo
            ),
            isSpoiler: model.isSpoiler
        )
    }
}
