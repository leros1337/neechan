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

    /// The file being viewed, shown over the grid.
    ///
    /// Presented from here rather than from the thread so that closing it comes
    /// back to the grid. Opening it from the thread meant the grid had to be
    /// dismissed first, and a reader who closed one picture was returned all the
    /// way to the posts and had to open the gallery again.
    @State private var start: GalleryStart?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            start = GalleryStart(items: items, index: index)
                        } label: {
                            ThumbnailView(attachment: item.attachment, side: nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(for: item))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
                        Text("Done", bundle: .module)
                    }
                }
            }
        }
    }

    private func label(for item: GalleryItem) -> Text {
        item.attachment.isVideo
            ? Text("Video in post \(item.postNum)", bundle: .module)
            : Text("Image in post \(item.postNum)", bundle: .module)
    }
}
