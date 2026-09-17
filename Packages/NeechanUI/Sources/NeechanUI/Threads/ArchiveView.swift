import NeechanAPI
import NeechanCore
import SwiftUI

/// A board's archive: threads that have fallen off the last page.
///
/// The archive lists only a subject and a date, so the rows are plain text and
/// the thread itself is fetched when one is opened.
struct ArchiveView: View {
    let board: String

    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var threads: [ArchivedThread] = []
    @State private var pageNumbers: [Int] = []
    @State private var page = 0
    @State private var loadState: LoadState = .idle
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(visibleThreads) { thread in
                Button {
                    router.push(
                        .thread(ThreadKey(site: services.site, board: board, threadNum: thread.threadNum))
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(of: thread))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                        Text(thread.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hasNextPage {
                Button {
                    Task { await load(page: page + 1) }
                } label: {
                    Label {
                        Text("Older threads", bundle: .module)
                    } icon: {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $searchText, prompt: Text("Filter archive", bundle: .module))
        .refreshable { await load(page: page) }
        .navigationTitle(Text("Archive of /\(board)/", bundle: .module))
        .inlineNavigationTitle()
        .overlay { stateOverlay }
        .task { await load(page: 0) }
    }

    private var visibleThreads: [ArchivedThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threads }
        return threads.filter { $0.subject.localizedCaseInsensitiveContains(query) }
    }

    private var hasNextPage: Bool {
        pageNumbers.contains(page + 1)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch loadState {
        case .loading where threads.isEmpty:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("No archive", bundle: .module)
                } icon: {
                    Image(systemName: "archivebox")
                }
            } description: {
                Text(message)
            }
        case .loaded where visibleThreads.isEmpty:
            if searchText.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("The archive is empty", bundle: .module)
                    } icon: {
                        Image(systemName: "archivebox")
                    }
                }
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }

    private func title(of thread: ArchivedThread) -> String {
        let subject = thread.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? "/\(board)/\(thread.threadNum)" : subject
    }

    /// Loads a page, appending when it is a later one so the list grows rather
    /// than jumping back to the top.
    private func load(page target: Int) async {
        loadState = .loading
        do {
            let result = try await services.archive.page(board: board, page: target)
            if target == 0 {
                threads = result.threads
            } else {
                let known = Set(threads.map(\.threadNum))
                threads += result.threads.filter { !known.contains($0.threadNum) }
            }
            pageNumbers = result.pageNumbers
            page = target
            loadState = .loaded
        } catch {
            loadState = .failed(error.readableMessage)
        }
    }
}
