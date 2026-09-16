import NeechanAPI
import NeechanCore
import SwiftUI

/// Searches a board on the server, which reaches posts the device never loaded.
///
/// The in-thread search filters what is already in hand; this asks the site.
struct ServerSearchView: View {
    let board: String

    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var query = ""
    @State private var results: [Post] = []
    @State private var loadState: LoadState = .idle

    var body: some View {
        List {
            ForEach(results) { post in
                Button {
                    open(post)
                } label: {
                    SearchResultRow(post: post, board: board)
                }
            }
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $query, prompt: Text("Search /\(board)/", bundle: .module))
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .navigationTitle(Text("Search", bundle: .module))
        .inlineNavigationTitle()
        .overlay { stateOverlay }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch loadState {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Nothing found", bundle: .module)
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            } description: {
                Text(message)
            }
        case .idle:
            ContentUnavailableView {
                Label {
                    Text("Search this board", bundle: .module)
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            } description: {
                Text("The site searches every thread, including ones you have not opened.", bundle: .module)
            }
        case .loaded where results.isEmpty:
            ContentUnavailableView.search(text: query)
        case .loaded:
            EmptyView()
        }
    }

    /// A search result points at a post; opening it goes to the post's thread
    /// and scrolls there, since a reply on its own has no context.
    private func open(_ post: Post) {
        let threadNum = post.parent == 0 ? post.num : post.parent
        router.push(
            .thread(ThreadKey(board: board, threadNum: threadNum), scrollTo: post.num)
        )
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        loadState = .loading
        do {
            results = try await services.search.search(board: board, text: text)
            loadState = .loaded
        } catch {
            results = []
            loadState = .failed(error.readableMessage)
        }
    }
}

extension SearchService.SearchError {
    /// A sentence to put in front of the reader.
    var readableMessage: String {
        switch self {
        case .queryTooShort(let minimum):
            String(
                localized: "Type at least \(minimum) characters.",
                bundle: .neechanUI
            )
        case .failed(let message):
            message
        }
    }
}

/// One post as a search result: who, when, and the first lines of what it says.
struct SearchResultRow: View {
    let post: Post
    let board: String

    /// Results are a page at a time, so parsing each comment as it is drawn is
    /// cheap enough not to need the thread list's cache.
    private var commentText: String {
        CommentHTMLParser()
            .parse(post.comment, inThread: post.threadNum, onBoard: post.board)
            .plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: "#\(post.num)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !post.subject.isEmpty {
                    Text(post.subject)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                Spacer()
                Text(post.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(commentText)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(4)
        }
    }
}
