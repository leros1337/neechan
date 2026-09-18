import NeechanCore
import NeechanMedia
import SwiftUI

/// Files staged for the post.
struct AttachmentStrip: View {
    let attachments: [DraftAttachmentState]
    var onRemove: (UUID) -> Void
    var onEdit: (DraftAttachmentState) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    AttachmentTile(
                        attachment: attachment,
                        onRemove: { onRemove(attachment.id) },
                        onEdit: { onEdit(attachment) }
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

    @State private var preview: PlatformImage?

    var body: some View {
        Button(action: onEdit) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let preview {
                            Image(platformImage: preview)
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
        .task(id: attachment.id) {
            guard
                let data = try? DraftRepository.attachmentData(at: attachment.localRelativePath)
            else {
                return
            }
            preview = PlatformImage(data: data)
        }
    }
}

/// Per-file options, opened by tapping a staged file.
struct AttachmentOptionsSheet: View {
    @State private var attachment: DraftAttachmentState
    private let onSave: (DraftAttachmentState) -> Void

    @Environment(\.dismiss) private var dismiss

    init(attachment: DraftAttachmentState, onSave: @escaping (DraftAttachmentState) -> Void) {
        _attachment = State(initialValue: attachment)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
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
                        Stepper(
                            value: Binding(
                                get: { attachment.processing.scalePercent ?? 100 },
                                set: { attachment.processing.scalePercent = $0 == 100 ? nil : $0 }
                            ),
                            in: 10...100,
                            step: 10
                        ) {
                            Text("Scale: \(attachment.processing.scalePercent ?? 100)%", bundle: .module)
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
}
