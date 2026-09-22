import NeechanCore
import SwiftUI

/// The report form: what is wrong, and send.
///
/// The 2ch shape. One field, because that is all the site takes: no captcha, no
/// category list, no attachments. 4chan is reported through ``ReportWebView``
/// instead, which is its own page.
struct ReportFormView: View {
    private let board: String
    private let thread: Int
    private let postNum: Int
    /// Called once the site has accepted the report, so the screen behind can
    /// say so.
    private var onReported: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReportFormViewModel?
    @FocusState private var isCommentFocused: Bool

    init(
        board: String,
        thread: Int,
        postNum: Int,
        onReported: @escaping () -> Void = {}
    ) {
        self.board = board
        self.thread = thread
        self.postNum = postNum
        self.onReported = onReported
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Text("Report post", bundle: .module))
            .inlineNavigationTitle()
            .toolbar { toolbar }
        }
        .task {
            guard model == nil else { return }
            model = ReportFormViewModel(
                board: board, thread: thread, postNum: postNum, services: services
            )
            isCommentFocused = true
        }
    }

    @ViewBuilder
    private func form(_ model: ReportFormViewModel) -> some View {
        @Bindable var model = model

        Form {
            Section {
                TextField(text: $model.comment, axis: .vertical) {
                    Text("What is wrong with this post?", bundle: .module)
                }
                .lineLimit(4...)
                .focused($isCommentFocused)
                .accessibilityIdentifier("report-comment")
            } header: {
                Text("Post №\(postNum)", bundle: .module)
            } footer: {
                // Named plainly: the report goes to the people who run the
                // board, not to us, and a reader deciding whether to write one
                // should know who reads it.
                Text(
                    "This goes to the moderators of the imageboard, who decide what happens to the post. Neechan does not host it and cannot remove it.",
                    bundle: .module
                )
            }

            errorSection(model)
        }
        .onChange(of: model.sendState) { _, state in
            if case .sent = state {
                onReported()
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func errorSection(_ model: ReportFormViewModel) -> some View {
        if case .failed(let message) = model.sendState {
            Section {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .font(.footnote)
                .accessibilityIdentifier("report-error")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Label {
                    Text("Cancel", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await model?.send() }
            } label: {
                Label {
                    Text("Send", bundle: .module)
                } icon: {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(model?.canSend != true)
            .accessibilityIdentifier("report-send")
        }
    }
}
