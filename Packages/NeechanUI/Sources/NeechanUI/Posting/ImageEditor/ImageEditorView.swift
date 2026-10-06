import NeechanCore
import SwiftUI

/// Draw on, crop, turn and resize a staged picture before it is posted.
///
/// Presented over the reply form as a cover. It touches nothing until Done:
/// then the edited picture is written once and handed back to replace the
/// staged file.
struct ImageEditorView: View {
    private let attachment: DraftAttachmentState
    /// Called with the edited picture; the editor closes once it returns.
    private let onEdited: (ImageEditOutput) async -> Void

    @State private var model = ImageEditorModel()
    @State private var isConfirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(attachment: DraftAttachmentState, onEdited: @escaping (ImageEditOutput) async -> Void) {
        self.init(attachment: attachment, model: ImageEditorModel(), onEdited: onEdited)
    }

    /// With a model from outside, for previews and for driving it in tests.
    init(
        attachment: DraftAttachmentState,
        model: ImageEditorModel,
        onEdited: @escaping (ImageEditOutput) async -> Void
    ) {
        self.attachment = attachment
        _model = State(initialValue: model)
        self.onEdited = onEdited
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .loading:
                ProgressView()
            case .failed:
                failure
            case .ready, .exporting:
                editor
                    // The keyboard is for labels, which have a layer of their
                    // own above it; the picture should not jump when it opens.
                    .ignoresSafeArea(.keyboard)
            }

            if model.labelEditing != nil {
                LabelEntryOverlay(model: model)
                    .transition(.opacity)
            }

            if model.phase == .exporting {
                ProgressView()
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.labelEditing?.id)
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
        .hidesStatusBar(true)
        .task { await load() }
        .confirmationDialog(
            Text("Discard changes?", bundle: .module),
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                dismiss()
            } label: {
                Text("Discard", bundle: .module)
            }
            Button(role: .cancel) {} label: {
                Text("Keep editing", bundle: .module)
            }
        }
    }

    // MARK: Layout

    private var editor: some View {
        VStack(spacing: 0) {
            topBar
                // The label layer has its own Done in the same place.
                .opacity(model.labelEditing == nil ? 1 : 0)
            ImageEditorCanvas(model: model)
            bottomPanel
        }
        .disabled(model.phase == .exporting)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: cancel) {
                Label {
                    Text("Cancel", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: model.undo) {
                        Label {
                            Text("Undo", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)

                    Button(action: model.redo) {
                        Label {
                            Text("Redo", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.uturn.forward")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                }
            }

            Spacer(minLength: 8)

            PixelSizeChip(size: model.outputPixelSize)

            Spacer(minLength: 8)

            Button(action: done) {
                Label {
                    Text("Done", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .duoAvoidingOcclusions()
    }

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            Group {
                switch model.mode {
                case .draw: DrawPanel(model: model)
                case .crop: CropPanel(model: model)
                case .resize: ResizePanel(model: model)
                }
            }
            .frame(maxWidth: 560)

            Picker(selection: $model.mode) {
                Text("Draw", bundle: .module).tag(ImageEditorModel.Mode.draw)
                Text("Crop", bundle: .module).tag(ImageEditorModel.Mode.crop)
                Text("Resize", bundle: .module).tag(ImageEditorModel.Mode.resize)
            } label: {
                Text("Edit image", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var failure: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This picture can't be edited", bundle: .module)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Close", bundle: .module)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }

    // MARK: Actions

    private func load() async {
        guard model.phase == .loading else { return }
        let path = attachment.localRelativePath
        let data = await Task.detached(priority: .userInitiated) {
            try? DraftRepository.attachmentData(at: path)
        }.value
        await model.load(data: data ?? Data(), scalePercent: attachment.processing.scalePercent)
    }

    private func cancel() {
        if model.hasChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func done() {
        Task {
            switch await model.finish() {
            case .unchanged:
                dismiss()
            case .edited(let output):
                await onEdited(output)
                dismiss()
            case .failed:
                // The model shows the failure; Close is there.
                break
            }
        }
    }
}

/// The size of the file Done will write.
struct PixelSizeChip: View {
    let size: PixelSize

    var body: some View {
        Text("\(size.width) × \(size.height) px", bundle: .module)
            .font(.footnote.monospacedDigit())
            .lineLimit(1)
            // Shrinks rather than cuts off: the numbers are the point.
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }
}
