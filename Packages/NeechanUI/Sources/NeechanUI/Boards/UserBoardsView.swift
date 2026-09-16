import NeechanAPI
import NeechanCore
import SwiftUI

/// The boards readers made themselves.
///
/// The site files dozens of these under one category in the middle of the
/// directory, where they are hard to find; this is the same list on its own.
struct UserBoardsView: View {
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var boards: [Board] = []
    @State private var searchText = ""
    @State private var loadState: LoadState = .idle

    var body: some View {
        List(visibleBoards) { board in
            Button {
                router.push(.board(board.id))
            } label: {
                BoardRow(board: board)
            }
            .buttonStyle(.plain)
        }
        .groupedListStyle()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $searchText)
        .navigationTitle(Text("User boards", bundle: .module))
        .inlineNavigationTitle()
        .overlay { stateOverlay }
        .task { if boards.isEmpty { await load() } }
    }

    private var visibleBoards: [Board] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return boards }
        return boards.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch loadState {
        case .loading where boards.isEmpty:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could not load boards", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            }
        case .loaded where visibleBoards.isEmpty:
            ContentUnavailableView.search(text: searchText)
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }

    private func load() async {
        loadState = .loading
        do {
            boards = BoardsRepository.userBoards(in: try await services.boards.boards())
            loadState = .loaded
        } catch {
            loadState = .failed(error.readableMessage)
        }
    }
}
