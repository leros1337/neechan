import NeechanCore
import SwiftUI

/// Files staged for the post.
struct AttachmentStrip: View {
    let attachments: [DraftAttachmentState]
    var onRemove: (UUID) -> Void
    var onEdit: (DraftAttachmentState) -> Void
    /// Opens the picture in the image editor.
    var onEditImage: (DraftAttachmentState) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    AttachmentTile(
                        attachment: attachment,
                        onRemove: { onRemove(attachment.id) },
                        onEdit: { onEdit(attachment) },
                        onEditImage: { onEditImage(attachment) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

private struct AttachmentTile: View {
    let attachment: DraftAttachmentState
    var onRemove: () -> Void
    var onEdit: () -> Void
    var onEditImage: () -> Void

    @State private var preview: CGImage?
    @State private var isEditable = false

    var body: some View {
        Button(action: onEdit) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "doc")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 10))
                    // A wide picture still takes taps past its clipped edge,
                    // on the next tile and that tile's remove button.
                    .contentShape(.rect(cornerRadius: 10))

                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                }

                if attachment.processing.changesContent || attachment.isSpoiler {
                    // A small marker, so the reader can see at a glance that the
                    // file will not be uploaded exactly as it is on disk.
                    Image(systemName: "wand.and.sparkles")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isEditable {
                Button(action: onEditImage) {
                    Label {
                        Text("Edit image", bundle: .module)
                    } icon: {
                        Image(systemName: "pencil.and.scribble")
                    }
                }
            }
            Button(role: .destructive, action: onRemove) {
                Label {
                    Text("Remove", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        // Keyed on the file rather than the attachment, so an edit that
        // replaces the file shows at once.
        .task(id: attachment.localRelativePath) {
            let path = attachment.localRelativePath
            // Off the main thread, and only as large as the tile: a photo
            // decoded whole is a couple of hundred megabytes.
            let loaded = await Task.detached(priority: .utility) { () -> (CGImage?, Bool) in
                guard let data = try? DraftRepository.attachmentData(at: path) else { return (nil, false) }
                return (
                    ImageEditSource.decodeUpright(data, maxPixelSize: 228),
                    ImageEditSource(data: data)?.isEditable ?? false
                )
            }.value
            (preview, isEditable) = loaded
        }
    }
}

/// Per-file options, opened by tapping a staged file.
struct AttachmentOptionsSheet: View {
    @State private var attachment: DraftAttachmentState
    private let onSave: (DraftAttachmentState) -> Void
    /// Puts an edited picture in place of the file, returning the attachment
    /// as it then is.
    private let onReplace: (UUID, ImageEditOutput) async -> DraftAttachmentState?

    /// The file's header and a small picture of it, once read.
    @State private var source: ImageEditSource?
    @State private var thumbnail: CGImage?
    @State private var editorTarget: DraftAttachmentState?

    @Environment(\.dismiss) private var dismiss

    init(
        attachment: DraftAttachmentState,
        onSave: @escaping (DraftAttachmentState) -> Void,
        onReplace: @escaping (UUID, ImageEditOutput) async -> DraftAttachmentState?
    ) {
        _attachment = State(initialValue: attachment)
        self.onSave = onSave
        self.onReplace = onReplace
    }

    var body: some View {
        NavigationStack {
            Form {
                pictureSection

                Section {
                    Toggle(isOn: $attachment.processing.appendsUniqueHash) {
                        Text("Make the file unique", bundle: .module)
                    }
                    Toggle(isOn: $attachment.processing.stripsMetadata) {
                        Text("Remove metadata", bundle: .module)
                    }
                } footer: {
                    Text(
                        "The site refuses a file it has seen before. Removing metadata also strips location data from photos.",
                        bundle: .module
                    )
                }

                Section {
                    Toggle(
                        isOn: Binding(
                            get: { attachment.processing.reencodeQuality != nil },
                            set: { attachment.processing.reencodeQuality = $0 ? 85 : nil }
                        )
                    ) {
                        Text("Re-encode as JPEG", bundle: .module)
                    }
                    if let quality = attachment.processing.reencodeQuality {
                        Stepper(
                            value: Binding(
                                get: { quality },
                                set: { attachment.processing.reencodeQuality = $0 }
                            ),
                            in: 10...100,
                            step: 5
                        ) {
                            Text("Quality: \(quality)%", bundle: .module)
                        }
                    }
                }

                Section {
                    TextField(
                        text: Binding(
                            get: { attachment.processing.renameTo ?? "" },
                            set: { attachment.processing.renameTo = $0.isEmpty ? nil : $0 }
                        ),
                        prompt: Text("Keep the original name", bundle: .module)
                    ) {
                        Text("File name", bundle: .module)
                    }
                    .noAutocapitalization()
                } header: {
                    Text("Rename", bundle: .module)
                }
            }
            // Inside the sheet's own content: the reply form underneath is
            // already presenting this sheet and cannot present another.
            .fullScreenCoverCompat(item: $editorTarget) { target in
                ImageEditorView(attachment: target) { output in
                    guard let updated = await onReplace(target.id, output) else { return }
                    // Only what the edit changed: options toggled here since
                    // the sheet opened are still the reader's to save.
                    attachment.fileName = updated.fileName
                    attachment.localRelativePath = updated.localRelativePath
                    attachment.mimeType = updated.mimeType
                    attachment.processing.scalePercent = nil
                }
            }
            .task(id: attachment.localRelativePath) {
                let path = attachment.localRelativePath
                let loaded = await Task.detached(priority: .userInitiated) {
                    () -> (ImageEditSource?, CGImage?) in
                    guard let data = try? DraftRepository.attachmentData(at: path) else { return (nil, nil) }
                    return (ImageEditSource(data: data), ImageEditSource.decodeUpright(data, maxPixelSize: 192))
                }.value
                (source, thumbnail) = loaded
            }
            .navigationTitle(Text(attachment.fileName))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(attachment)
                        dismiss()
                    } label: {
                        Label {
                            Text("Done", bundle: .module)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The picture, its size as it will be sent, and the way into the editor.
    @ViewBuilder
    private var pictureSection: some View {
        if let source {
            Section {
                HStack(spacing: 14) {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                    PixelSizeText(size: sentSize(of: source))
                    Spacer(minLength: 0)
                    if source.isEditable {
                        Button {
                            editorTarget = attachment
                        } label: {
                            Label {
                                Text("Edit image", bundle: .module)
                            } icon: {
                                Image(systemName: "pencil.and.scribble")
                            }
                            // The name stays for VoiceOver; on screen it
                            // wrapped into a column of syllables.
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// The file's size, after any scale an older version saved with it.
    private func sentSize(of source: ImageEditSource) -> PixelSize {
        ImageEditGeometry(
            ImageEdit(uprightSize: source.uprightSize, scalePercent: attachment.processing.scalePercent ?? 100)
        ).outputPixelSize
    }
}

/// A picture's size in pixels.
private struct PixelSizeText: View {
    let size: PixelSize

    var body: some View {
        Text("\(size.width) × \(size.height) px", bundle: .module)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
