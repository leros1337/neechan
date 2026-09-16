import NeechanAPI
import NeechanCore
import SwiftUI

/// The board directory, grouped by the site's own categories.
public struct BoardsListView: View {
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var categories: [BoardsRepository.Category] = []
    @State private var searchText = ""
    @State private var loadState: LoadState = .idle

    public init() {}

    public var body: some View {
        List {
            // The board filter doubles as the app's "go to" field: a post
            // number, a board code or a pasted link all resolve here, which is
            // what the separate search tab used to be for.
            if let target = navigationTarget {
                Section {
                    Button {
                        router.open(target)
                        searchText = ""
                    } label: {
                        DestinationRow(target: target)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("go-to")
                } header: {
                    Text("Go to", bundle: .module)
                }
            }

            if searchText.isEmpty {
                Section {
                    Button {
                        router.push(.userBoards)
                    } label: {
                        Label {
                            Text("User boards", bundle: .module)
                        } icon: {
                            Image(systemName: "person.2")
                        }
                    }
                }
            }

            ForEach(filteredCategories) { category in
                Section(category.name.isEmpty ? String(localized: "Other", bundle: .module, locale: AppLocale.current) : category.name) {
                    ForEach(category.boards) { board in
                        Button {
                            router.push(.board(board.id))
                        } label: {
                            BoardRow(board: board)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .groupedListStyle()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $searchText)
        .navigationTitle(Text("Boards", bundle: .module))
        .refreshable { await load(forceRefresh: true) }
        .overlay { stateOverlay }
        .task { if categories.isEmpty { await load() } }
    }

    /// The destination the query resolves to, if it is one.
    private var navigationTarget: NavigationTarget? {
        NavigationQueryParser.parse(searchText, currentBoard: services.settings.defaultBoard)
    }

    private var filteredCategories: [BoardsRepository.Category] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Browsing: the reader-made boards are dozens of rows in the middle of
        // the directory and have a screen of their own, reached by the row
        // above. Searching still reaches them, so a code typed in still lands.
        guard !query.isEmpty else {
            return categories.filter { $0.name != BoardsRepository.userBoardCategory }
        }

        return categories.compactMap { category in
            let matches = category.boards.filter {
                $0.id.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty
                ? nil
                : BoardsRepository.Category(name: category.name, boards: matches)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch loadState {
        case .loading where categories.isEmpty:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could not load boards", bundle: .module)
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                }
            } description: {
                Text(message)
            } actions: {
                Button {
                    Task { await load(forceRefresh: true) }
                } label: {
                    Text("Try again", bundle: .module)
                }
                .buttonStyle(.glassProminent)
            }
        case .idle, .loading, .loaded:
            if case .loaded = loadState, filteredCategories.isEmpty, navigationTarget == nil {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func load(forceRefresh: Bool = false) async {
        loadState = .loading
        do {
            categories = try await services.boards.categories(forceRefresh: forceRefresh)
            loadState = .loaded
        } catch {
            loadState = .failed(error.readableMessage)
        }
    }
}

/// One board in the directory.
struct BoardRow: View {
    let board: Board

    var body: some View {
        HStack(spacing: 12) {
            Text(board.displayCode)
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.tint)
                .frame(minWidth: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(board.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !board.allowsPosting {
                    Text("Read only", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }
}

private struct DestinationRow: View {
    let target: NavigationTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private var icon: String {
        switch target {
        case .board: "square.grid.2x2"
        case .thread, .threadAtPost, .post: "bubble.left.and.text.bubble.right"
        }
    }

    private var title: String {
        switch target {
        case .board(let board): "/\(board)/"
        case .thread(let board, let threadNum): "/\(board)/\(threadNum)"
        case .threadAtPost(let board, let threadNum, let postNum): "/\(board)/\(threadNum) → \(postNum)"
        case .post(let board, let num): "/\(board)/ №\(num)"
        }
    }

    private var subtitle: Text {
        switch target {
        case .board: Text("Open this board", bundle: .module)
        case .thread: Text("Open this thread", bundle: .module)
        case .threadAtPost: Text("Open the thread at that post", bundle: .module)
        case .post: Text("Open this post", bundle: .module)
        }
    }
}

/// The three states any fetching screen can be in.
enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
