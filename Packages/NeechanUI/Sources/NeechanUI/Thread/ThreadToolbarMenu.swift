import NeechanAPI
import NeechanCore
import SwiftUI

/// The thread's overflow menu.
///
/// A view of its own rather than a `Menu` built inside `ThreadView.body`: the
/// menu reads the favourite state, the saved state, the hidden count and the
/// thread's counters, and a `@ToolbarContentBuilder` method is evaluated as part
/// of its parent's body, so every one of those reads used to invalidate the
/// whole thread. Here they invalidate a menu nobody is looking at.
struct ThreadToolbarMenu: View {
    @Environment(AppServices.self) private var services

    let model: ThreadViewModel
    /// The thread's own address, when the mirror could produce one.
    let threadURL: URL?
    /// How many posts the search is showing, for the counter section.
    let matchCount: Int

    var onSearch: () -> Void
    var onShowGallery: () -> Void
    var onShowDoomscroll: () -> Void
    var onShowHiddenPosts: () -> Void
    var onReload: () -> Void
    /// Saves the thread; true also downloads the files.
    var onSave: (Bool) -> Void

    var body: some View {
        Menu {
            Button {
                Task { await model.toggleFavorite() }
            } label: {
                Label {
                    Text(
                        model.isFavorite ? "Remove from favorites" : "Add to favorites",
                        bundle: .module
                    )
                } icon: {
                    Image(systemName: model.isFavorite ? "star.fill" : "star")
                }
            }
            Button(action: onSearch) {
                Label {
                    Text("Search in thread", bundle: .module)
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            }
            Button(action: onShowGallery) {
                Label {
                    Text("Gallery", bundle: .module)
                } icon: {
                    Image(systemName: "photo.on.rectangle")
                }
            }
            .disabled(!model.snapshot.hasAttachments)

            Button(action: onShowDoomscroll) {
                Label {
                    Text("Doomscroll", bundle: .module)
                } icon: {
                    Image(systemName: "play.square.stack")
                }
            }
            .disabled(!model.snapshot.hasVideos)
            .accessibilityIdentifier("doomscroll")

            if !model.isOffline {
                Button(action: onReload) {
                    Label {
                        Text("Reload", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                // Offered only where the saved copy can be read back. The
                // archiver keeps the server's own bytes and re-reads them as
                // 2ch's thread shape, so saving a 4chan thread would write a
                // file nothing could open — better no button than a broken one.
                if services.capabilities.savingThreads {
                    Menu {
                        Button { onSave(false) } label: {
                            Text("Text and thumbnails", bundle: .module)
                        }
                        Button { onSave(true) } label: {
                            Text("Everything, including files", bundle: .module)
                        }
                    } label: {
                        Label {
                            Text(
                                model.isSaved ? "Update saved copy" : "Save for offline",
                                bundle: .module
                            )
                        } icon: {
                            Image(
                                systemName: model.isSaved
                                    ? "arrow.down.circle.fill" : "arrow.down.circle"
                            )
                        }
                    }
                    // Its label changes with whether a copy exists, so a test
                    // that looked for the words would only ever find one state.
                    .accessibilityIdentifier("save-for-offline")
                }
            }
            if let threadURL {
                Section {
                    LinkActionsMenu(url: threadURL, title: model.snapshot.meta.title)
                }
            }
            if !model.hiddenPostNums.isEmpty {
                Button(action: onShowHiddenPosts) {
                    Label {
                        Text("\(model.hiddenPostNums.count) hidden posts", bundle: .module)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                }
            }
            Section {
                if model.isSearching {
                    Text("\(matchCount) matches", bundle: .module)
                }
                Text("\(model.snapshot.meta.postsCount) posts", bundle: .module)
                Text("\(model.snapshot.meta.filesCount) files", bundle: .module)
                if model.snapshot.meta.uniquePosters > 0 {
                    Text("\(model.snapshot.meta.uniquePosters) posters", bundle: .module)
                }
            }
        } label: {
            Label {
                Text("Thread actions", bundle: .module)
            } icon: {
                Image(systemName: "ellipsis")
            }
        }
    }
}
