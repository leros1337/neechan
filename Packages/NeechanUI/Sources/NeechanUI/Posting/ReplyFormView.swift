import NeechanAPI
import NeechanCore
import PhotosUI
import SwiftUI

/// The reply form: comment, optional fields, attachments, captcha and send.
public struct ReplyFormView: View {
    private let board: String
    private let thread: Int?
    /// Post to quote when the form opens.
    private let quoting: Int?
    /// Called with the thread to open after a successful post.
    private var onPosted: (PostingOutcome) -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReplyFormViewModel?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isShowingFileImporter = false
    @State private var editingAttachment: DraftAttachmentState?
    @FocusState private var isCommentFocused: Bool

    public init(
        board: String,
        thread: Int?,
        quoting: Int? = nil,
        onPosted: @escaping (PostingOutcome) -> Void = { _ in }
    ) {
        self.board = board
        self.thread = thread
        self.quoting = quoting
        self.onPosted = onPosted
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(
                thread == nil
                    ? Text("New thread", bundle: .module)
                    : Text("Reply", bundle: .module)
            )
            .inlineNavigationTitle()
            .toolbar { toolbar }
        }
        // Asked for again once a browser check has been passed: the captcha is
        // the request a gate refuses first, and the reader has just done the
        // one thing that would let it through.
        .task(id: services.challengesPassed) {
            guard let model, services.challengesPassed > 0 else { return }
            await model.loadCaptcha()
        }
        .task {
            guard model == nil else { return }
            let model = ReplyFormViewModel(board: board, thread: thread, services: services)
            self.model = model
            await model.start()
            if let quoting {
                model.insertQuote(of: quoting)
            }
            isCommentFocused = true
        }
    }

    // MARK: Body

    /// Split into small pieces deliberately: as one expression the form is
    /// past what the type checker will solve in reasonable time.
    @ViewBuilder
    private func form(_ model: ReplyFormViewModel) -> some View {
        @Bindable var model = model

        Form {
            identitySection(model)
            commentSection(model)
            attachmentsSection(model)
            captchaSection(model)
            optionsSection(model)
            errorSection(model)
        }
        // The captcha sits below the comment field, so scrolling must be able
        // to get the keyboard out of the way to reach it.
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            MarkupToolbar(
                canAttach: model.draft.attachments.count < model.maxAttachments,
                onStyle: {
                    model.applyMarkup($0)
                    // Reaching for the toolbar can take the keyboard away, and
                    // the reader is mid-sentence.
                    isCommentFocused = true
                },
                onPickPhotos: {},
                photoSelection: $photoSelection,
                onPickFiles: { isShowingFileImporter = true }
            )
        }
        .overlay { sendingOverlay(model) }
        .sheet(item: $editingAttachment) { attachment in
            AttachmentOptionsSheet(attachment: attachment) { model.updateAttachment($0) }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result, into: model) }
        }
        .onChange(of: photoSelection) { _, items in
            Task { await importPhotos(items, into: model) }
        }
        .onChange(of: model.sendState) { _, state in
            if case .sent(let outcome) = state {
                onPosted(outcome)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func identitySection(_ model: ReplyFormViewModel) -> some View {
        @Bindable var model = model
        let allowsSubject = model.boardInfo?.allowsSubject ?? false
        let allowsNames = model.boardInfo?.allowsNames ?? false

        if allowsSubject || allowsNames {
            Section {
                if allowsSubject {
                    TextField(
                        text: $model.draft.subject,
                        prompt: Text("Subject", bundle: .module)
                    ) {
                        Text("Subject", bundle: .module)
                    }
                }
                if allowsNames {
                    TextField(
                        text: $model.draft.name,
                        prompt: Text("Name, or name#tripcode", bundle: .module)
                    ) {
                        Text("Name", bundle: .module)
                    }
                    .noAutocapitalization()
                }
            }
        }
    }

    @ViewBuilder
    private func commentSection(_ model: ReplyFormViewModel) -> some View {
        @Bindable var model = model

        Section {
            TextEditor(text: $model.draft.comment, selection: $model.commentSelection)
                .frame(minHeight: 140)
                .focused($isCommentFocused)
                .onChange(of: model.draft.comment) { _, _ in model.scheduleAutosave() }
        } header: {
            Text("Comment", bundle: .module)
        } footer: {
            CharacterCounter(count: model.draft.comment.count, limit: model.commentLimit)
        }
    }

    @ViewBuilder
    private func attachmentsSection(_ model: ReplyFormViewModel) -> some View {
        if !model.draft.attachments.isEmpty {
            Section {
                AttachmentStrip(
                    attachments: model.draft.attachments,
                    onRemove: { model.removeAttachment($0) },
                    onEdit: { editingAttachment = $0 }
                )
            } header: {
                Text("Attachments", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private func captchaSection(_ model: ReplyFormViewModel) -> some View {
        @Bindable var model = model
        Section {
            EmojiCaptchaView(
                state: model.captcha,
                sliderResponse: $model.sliderResponse,
                secondsRemaining: model.captchaSecondsRemaining,
                chosenKeys: model.chosenCaptchaKeys,
                onSelect: { await model.selectEmoji(at: $0) },
                onReload: { await model.loadCaptcha() }
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func optionsSection(_ model: ReplyFormViewModel) -> some View {
        @Bindable var model = model

        if model.boardInfo?.allowsSage ?? false {
            Section {
                Toggle(isOn: $model.draft.isSage) {
                    Text("Sage (do not bump)", bundle: .module)
                }
                if thread != nil {
                    Toggle(isOn: $model.draft.isOriginalPoster) {
                        Text("Post as OP", bundle: .module)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func errorSection(_ model: ReplyFormViewModel) -> some View {
        if case .failed(let message, _) = model.sendState {
            Section {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func sendingOverlay(_ model: ReplyFormViewModel) -> some View {
        if case .sending(let stage) = model.sendState {
            SendProgressOverlay(stage: stage)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                Task {
                    await model?.saveNow()
                    dismiss()
                }
            } label: {
                Text("Cancel", bundle: .module)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await model?.send() }
            } label: {
                Text("Send", bundle: .module)
            }
            .buttonStyle(.glassProminent)
            .disabled(model?.canSend != true)
        }
    }

    // MARK: Attaching

    private func importPhotos(_ items: [PhotosPickerItem], into model: ReplyFormViewModel) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let fileExtension = type?.preferredFilenameExtension ?? "jpg"
            model.attach(
                data: data,
                fileName: "\(UUID().uuidString.prefix(8)).\(fileExtension)",
                mimeType: type?.preferredMIMEType ?? "image/jpeg"
            )
        }
        photoSelection = []
    }

    private func importFiles(
        _ result: Result<[URL], any Error>,
        into model: ReplyFormViewModel
    ) async {
        guard case .success(let urls) = result else { return }
        for url in urls {
            // Files chosen outside the app's container need their security
            // scope opened before they can be read.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else { continue }
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            model.attach(
                data: data,
                fileName: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream"
            )
        }
    }
}

/// Characters used against the board's limit.
private struct CharacterCounter: View {
    let count: Int
    let limit: Int

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(verbatim: "\(count) / \(limit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(count > limit ? .red : .secondary)
        }
    }
}

/// Shown while a post is on its way.
private struct SendProgressOverlay: View {
    let stage: PostingCoordinator.Stage

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                label
                    .font(.footnote)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }

    private var label: Text {
        switch stage {
        case .preparingFiles: Text("Preparing files…", bundle: .module)
        case .solvingProofOfWork: Text("Solving the challenge…", bundle: .module)
        case .uploading: Text("Sending…", bundle: .module)
        case .done: Text("Sent", bundle: .module)
        }
    }
}
