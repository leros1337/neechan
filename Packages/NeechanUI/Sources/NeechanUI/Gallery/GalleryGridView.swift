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
    @State private var browserLink: BrowserLink?
    /// Not kept between openings: a thread with no video would otherwise open
    /// on an empty grid.
    @State private var filter: GalleryFilter

    init(
        items: [GalleryItem],
        services: AppServices,
        filter: GalleryFilter = .all,
        onGoToPost: ((Int) -> Void)? = nil
    ) {
        self.items = items
        self.onGoToPost = onGoToPost
        _model = State(initialValue: GalleryGridModel(services: services))
        _filter = State(initialValue: filter)
    }

    /// The file being viewed, shown over the grid.
    ///
    /// Presented from here rather than from the thread so that closing it comes
    /// back to the grid. Opening it from the thread meant the grid had to be
    /// dismissed first, and a reader who closed one picture was returned all the
    /// way to the posts and had to open the gallery again.
    @State private var start: GalleryStart?

    var body: some View {
        let shown = filter.apply(to: items)
        NavigationStack {
            ScrollView {
                DuoAdaptiveGrid(minimum: 104, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if model.isSelecting {
                                model.toggleSelection(item)
                            } else {
                                // The viewer is given what the grid shows, so
                                // the index lands on the file tapped and a
                                // swipe stays within the filter.
                                start = GalleryStart(items: shown, index: index)
                            }
                        } label: {
                            ThumbnailView(attachment: item.attachment, side: nil)
                                .overlay(alignment: .bottomTrailing) {
                                    if model.isSelecting {
                                        SelectionMark(isSelected: model.isSelected(item))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(for: item))
                        .accessibilityAddTraits(model.isSelected(item) ? .isSelected : [])
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
                                onShare: { share(item) },
                                onReverseSearch: { openOffSite($0, settings: services.settings, in: $browserLink) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top) {
                if !items.isEmpty {
                    filterPicker
                }
            }
            .safeAreaBar(edge: .bottom) {
                if model.isSelecting {
                    selectionBar(shown: shown)
                }
            }
            .overlay(alignment: .bottom) {
                if let transfer = model.transfers.transfer {
                    TransferCapsule(transfer: transfer, batch: model.transfers.batch) { model.transfers.cancelTransfer() }
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
            .internalBrowser(link: $browserLink)
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
                } else if shown.isEmpty {
                    ContentUnavailableView {
                        Label {
                            if filter == .videos {
                                Text("No videos in this thread", bundle: .module)
                            } else {
                                Text("No images in this thread", bundle: .module)
                            }
                        } icon: {
                            Image(systemName: filter == .videos ? "film" : "photo")
                        }
                    } actions: {
                        Button {
                            filter = .all
                        } label: {
                            Text("Show all files", bundle: .module)
                        }
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
            .navigationTitle(title(count: shown.count))
            .inlineNavigationTitle()
            .toolbar {
                if !items.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            model.isSelecting.toggle()
                        } label: {
                            if model.isSelecting {
                                Text("Cancel", bundle: .module)
                            } else {
                                Text("Select", bundle: .module)
                            }
                        }
                        .accessibilityIdentifier("gallery-select")
                    }
                }
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

    /// Select all, and the save the picking is for.
    private func selectionBar(shown: [GalleryItem]) -> some View {
        let count = model.selectionCount(in: shown)
        let allPicked = !shown.isEmpty && count == shown.count
        return HStack {
            Button {
                model.toggleSelectAll(in: shown)
            } label: {
                if allPicked {
                    Text("Deselect all", bundle: .module)
                } else {
                    Text("Select all", bundle: .module)
                }
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("gallery-select-all")

            Spacer()

            Button {
                model.saveSelection(in: shown)
            } label: {
                Label {
                    Text("Save \(count)", bundle: .module)
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(count == 0)
            .accessibilityIdentifier("gallery-save-selection")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// A segmented control rather than a menu: readers flip between the three,
    /// so one tap beats two, and which one is on stays in sight.
    private var filterPicker: some View {
        Picker(selection: $filter) {
            Text("All", bundle: .module).tag(GalleryFilter.all)
            Text("Videos", bundle: .module).tag(GalleryFilter.videos)
            Text("Images", bundle: .module).tag(GalleryFilter.images)
        } label: {
            Text("Show", bundle: .module)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("gallery-filter")
    }

    /// Counts what is shown, and names it.
    private func title(count: Int) -> Text {
        switch filter {
        case .all: Text("\(count) attachments", bundle: .module)
        case .videos: Text("\(count) videos", bundle: .module)
        case .images: Text("\(count) images", bundle: .module)
        }
    }

    /// Downloads the file and hands it to the share sheet.
    private func share(_ item: GalleryItem) {
        Task {
            shareURL = await model.fileForSharing(item)
        }
    }

    /// Said in place of the thumbnail's own description, so the length its
    /// corner shows is said here too.
    private func label(for item: GalleryItem) -> Text {
        if let duration = item.attachment.durationLabel {
            Text("Video in post \(item.postNum), \(duration)", bundle: .module)
        } else if item.attachment.isVideo {
            Text("Video in post \(item.postNum)", bundle: .module)
        } else {
            Text("Image in post \(item.postNum)", bundle: .module)
        }
    }
}

/// Identifiable wrapper so the share sheet can be driven by a file URL.
private struct GridShareTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The tick in the corner of a file while files are being picked.
private struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.3))
            .shadow(radius: 2)
            .padding(6)
            .accessibilityHidden(true)
    }
}
