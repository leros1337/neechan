import NeechanAPI
import NeechanCore
import SwiftUI

/// Every attachment in a thread, as a grid.
///
/// Reading a thread for its pictures means scrolling past the text to find
/// them; this puts them all in one place, and opening one lands in the same
/// viewer a tap in the thread would.
struct GalleryGridView: View {
    let items: [GalleryItem]
    /// Passed through to the viewer, and taken as a cue to close the grid as
    /// well: going to a post means leaving both of these behind.
    var onGoToPost: ((Int) -> Void)?

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Saving and sharing from a long press, without opening the file first.
    @State private var model: GalleryGridModel
    @State private var shareURL: URL?

    init(items: [GalleryItem], services: AppServices, onGoToPost: ((Int) -> Void)? = nil) {
        self.items = items
        self.onGoToPost = onGoToPost
        _model = State(initialValue: GalleryGridModel(services: services))
    }

    /// The file being viewed, shown over the grid.
    ///
    /// Presented from here rather than from the thread so that closing it comes
    /// back to the grid. Opening it from the thread meant the grid had to be
    /// dismissed first, and a reader who closed one picture was returned all the
    /// way to the posts and had to open the gallery again.
    @State private var start: GalleryStart?

    var body: some View {
        NavigationStack {
            ScrollView {
                DuoAdaptiveGrid(minimum: 104, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            start = GalleryStart(items: items, index: index)
                        } label: {
                            ThumbnailView(attachment: item.attachment, side: nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(for: item))
                        // The same menu the viewer offers. The system's own
                        // lift is fine here, unlike in the viewer: the cell is
                        // a thumbnail, and cheap to draw twice.
                        .contextMenu {
                            GalleryItemMenu(
                                item: item,
                                onGoToPost: onGoToPost.map { goToPost in
                                    {
                                        dismiss()
                                        goToPost(item.postNum)
                                    }
                                },
                                onSave: { model.save(item) },
                                onShare: { share(item) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay(alignment: .bottom) {
                if let transfer = model.transfers.transfer {
                    TransferCapsule(transfer: transfer) { model.transfers.cancelTransfer() }
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: model.transfers.transfer)
            // The tick clears itself once it has been on screen long enough to read.
            .task(id: model.transfers.transfer?.isFinished) {
                guard model.transfers.transfer?.isFinished == true else { return }
                await model.transfers.clearFinishedTransfer()
            }
            .sensoryFeedback(trigger: model.transfers.lastVideoSave) { _, outcome in
                SaveHaptic.feedback(for: outcome)
            }
            .sheet(item: Binding(
                get: { shareURL.map(GridShareTarget.init) },
                set: { shareURL = $0?.url }
            )) { target in
                ShareSheet(items: [target.url])
            }
            // Only failures interrupt: a save that worked says so in the capsule.
            .alert(item: Binding(
                get: { model.transfers.saveResult },
                set: { model.transfers.saveResult = $0 }
            )) { result in
                Alert(
                    title: Text("Could not save", bundle: .module),
                    message: Text(result.message),
                    dismissButton: .default(Text("OK", bundle: .module))
                )
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No attachments", bundle: .module)
                        } icon: {
                            Image(systemName: "photo.on.rectangle")
                        }
                    } description: {
                        Text("Nothing has been posted in this thread yet.", bundle: .module)
                    }
                }
            }
            .fullScreenCoverCompat(item: $start) { start in
                GalleryView(
                    items: start.items,
                    startIndex: start.index,
                    services: services,
                    onGoToPost: onGoToPost.map { goToPost in
                        { postNum in
                            dismiss()
                            goToPost(postNum)
                        }
                    }
                )
            }
            .navigationTitle(Text("\(items.count) attachments", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
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
    }

    /// Downloads the file and hands it to the share sheet.
    private func share(_ item: GalleryItem) {
        Task {
            shareURL = await model.fileForSharing(item)
        }
    }

    private func label(for item: GalleryItem) -> Text {
        item.attachment.isVideo
            ? Text("Video in post \(item.postNum)", bundle: .module)
            : Text("Image in post \(item.postNum)", bundle: .module)
    }
}

/// Identifiable wrapper so the share sheet can be driven by a file URL.
private struct GridShareTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
