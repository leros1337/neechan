import NeechanCore
import NeechanSettings
import SwiftUI

/// Threads and boards the reader keeps, with what the watcher last saw.
public struct FavoritesView: View {
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var items: [FavoriteItem] = []
    @State private var boards: [FavoriteBoardItem] = []
    /// Kept in settings rather than in the view, so the Contents screen and
    /// this menu are the same preference.
    private var order: FavoritesOrder { services.settings.favoritesOrder }
    @State private var isRefreshing = false
    @State private var renaming: FavoriteItem?

    public init() {}

    public var body: some View {
        List {
            if !boards.isEmpty {
                Section {
                    ForEach(boards) { board in
                        Button {
                            router.push(.board(board.board))
                        } label: {
                            FavoriteBoardRow(item: board)
                        }
                        .buttonStyle(.plain)
                        // Named so a test can open one row on purpose rather
                        // than by counting: the two sections share a list.
                        .accessibilityIdentifier("favorite-board-\(board.board)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await removeBoard(board.board) }
                            } label: {
                                Label {
                                    Text("Remove", bundle: .module)
                                } icon: {
                                    Image(systemName: "star.slash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Boards", bundle: .module)
                }
            }

            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        Button {
                            router.push(.thread(item.key))
                        } label: {
                            FavoriteRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("favorite-thread-\(item.key.threadNum)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await remove(item) }
                            } label: {
                                Label {
                                    Text("Remove", bundle: .module)
                                } icon: {
                                    Image(systemName: "star.slash")
                                }
                            }
                            Button {
                                renaming = item
                            } label: {
                                Label {
                                    Text("Rename", bundle: .module)
                                } icon: {
                                    Image(systemName: "pencil")
                                }
                            }
                            .tint(.indigo)
                        }
                    }
                } header: {
                    Text("Threads", bundle: .module)
                }
            }
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(Text("Favorites", bundle: .module))
        .refreshable { await refreshNow() }
        .toolbar { toolbar }
        .overlay { emptyState }
        .sheet(item: $renaming) { item in
            RenameFavoriteSheet(item: item) { newName in
                Task { await rename(item, to: newName) }
            }
        }
        .task(id: order) {
            await load()
            await refreshIfStale()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the app is when a stale badge is most obvious.
            if phase == .active {
                Task {
                    await load()
                    await refreshIfStale()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Says the list is being brought up to date, which is otherwise
        // invisible until the badges change.
        if isRefreshing {
            ToolbarItem(placement: .navigation) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("favorites-refreshing")
            }
        }
        ToolbarItem(placement: .trailingBar) {
            Menu {
                Picker(selection: orderBinding) {
                    Text("Newest first", bundle: .module).tag(FavoritesOrder.newestFirst)
                    Text("Oldest first", bundle: .module).tag(FavoritesOrder.oldestFirst)
                    Text("By title", bundle: .module).tag(FavoritesOrder.title)
                    Text("Unread first", bundle: .module).tag(FavoritesOrder.unreadFirst)
                } label: {
                    Text("Sort", bundle: .module)
                }
                .pickerStyle(.inline)

                if items.contains(where: \.isDeleted) {
                    Button(role: .destructive) {
                        Task { await clearDeleted() }
                    } label: {
                        Label {
                            Text("Remove deleted", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            } label: {
                Label {
                    Text("View options", bundle: .module)
                } icon: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty, boards.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No favorites yet", bundle: .module)
                } icon: {
                    Image(systemName: "star")
                }
            } description: {
                Text("Threads and boards you keep appear here.", bundle: .module)
            }
        }
    }

    // MARK: Actions

    private var orderBinding: Binding<FavoritesOrder> {
        Binding(
            get: { services.settings.favoritesOrder },
            set: { services.settings.favoritesOrder = $0 }
        )
    }

    private func load() async {
        items = (try? await services.favorites.favorites(site: services.site, order: order)) ?? []
        boards = ((try? await services.favorites.favoriteBoards(site: services.site)) ?? [])
            .map { FavoriteBoardItem(board: $0.board, name: $0.name) }
    }

    private func refreshNow() async {
        await poll(skippingPolledWithin: nil)
    }

    /// Asks the site about the favourites whose counts have gone stale.
    ///
    /// Opening this tab should show what is new, but a full poll is one request
    /// per favourite, one after another: doing that every time the tab came up
    /// would make a quick look at the list cost several seconds. Anything the
    /// watcher checked inside its own interval is already current.
    private func refreshIfStale() async {
        await poll(skippingPolledWithin: .seconds(services.settings.watcherIntervalSeconds))
    }

    private func poll(skippingPolledWithin age: Duration?) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await services.watcher.pollOnce(skippingPolledWithin: age)
        await load()
    }

    private func remove(_ item: FavoriteItem) async {
        try? await services.favorites.remove(item.key)
        await load()
    }

    private func removeBoard(_ board: String) async {
        try? await services.favorites.removeBoard(BoardRef(site: services.site, code: board))
        await load()
    }

    private func rename(_ item: FavoriteItem, to name: String?) async {
        try? await services.favorites.rename(item.key, to: name)
        await load()
    }

    private func clearDeleted() async {
        try? await services.favorites.removeDeleted(site: services.site)
        await load()
    }
}

/// A pinned board, as a row.
struct FavoriteBoardItem: Identifiable, Hashable {
    let board: String
    let name: String
    var id: String { board }
}

struct FavoriteBoardRow: View {
    let item: FavoriteBoardItem

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "/\(item.board)/")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.tint)
            Text(item.name)
                .font(.body)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// A watched thread, with its unread badge and state.
struct FavoriteRow: View {
    let item: FavoriteItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(item.isDeleted ? .secondary : .primary)

                HStack(spacing: 6) {
                    Text(verbatim: "/\(item.key.board)/")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tint)
                    if item.isDeleted {
                        Text("Deleted", bundle: .module)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if item.isClosed {
                        Text("Closed", bundle: .module)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !item.isWatched {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            if item.unreadCount > 0 {
                UnreadBadge(count: item.unreadCount)
            }
        }
        .contentShape(.rect)
    }
}

/// How many posts have arrived since the thread was last read.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.tint, in: .capsule)
            .accessibilityLabel(Text("\(count) new posts", bundle: .module))
    }
}

/// Gives a favourite a name of the reader's own.
struct RenameFavoriteSheet: View {
    let item: FavoriteItem
    var onSave: (String?) -> Void

    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    text: $name,
                    prompt: Text("Use the site's title", bundle: .module)
                ) {
                    Text("Name", bundle: .module)
                }
            }
            .navigationTitle(Text("Rename", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label {
                            Text("Cancel", bundle: .module)
                        } icon: {
                            Image(systemName: "xmark")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(name.isEmpty ? nil : name)
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
        .presentationDetents([.height(200)])
        .onAppear { name = item.title }
    }
}
