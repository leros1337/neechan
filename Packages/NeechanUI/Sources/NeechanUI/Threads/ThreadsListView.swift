import NeechanAPI
import NeechanCore
import NeechanSettings
import SwiftUI

/// The thread list for one board, in whichever layout the reader picked.
public struct ThreadsListView: View {
    let board: String

    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var threads: [ThreadSummary] = []
    @State private var boardInfo: Board?
    @State private var loadState: LoadState = .idle
    @State private var searchText = ""
    /// The layout, kept in settings so it survives leaving the board.
    private var viewMode: ThreadsViewMode {
        services.settings.threadsViewMode(forBoard: board)
    }
    @State private var sort: CatalogSort = .bumpOrder
    @State private var isComposingThread = false
    @State private var galleryStart: GalleryStart?
    @State private var hiddenThreadNums: Set<Int> = []
    @State private var autohideRules: [AutohideRuleValue] = []
    /// Threads an autohide rule matches, worked out once per board rather than
    /// per row. Answering it per row meant parsing the opening post's HTML on
    /// the main actor several times for every thread on screen, on every pass.
    @State private var ruleHiddenNums: Set<Int> = []
    /// The threads the filter field leaves, recomputed when it settles.
    @State private var filteredThreads: [ThreadSummary] = []
    @State private var isBoardFavorite = false
    /// Catalog, or the site's own paging. Starts from the preference; the menu
    /// changes it for this board only.
    @State private var usesCatalog: Bool?
    @State private var pageIndex = 0
    @State private var pageCount = 1

    public init(board: String) {
        self.board = board
    }

    public var body: some View {
        content
            .navigationTitle(navigationTitle)
            .inlineNavigationTitle()
            .searchable(text: $searchText, prompt: Text("Filter threads", bundle: .module))
            .refreshable { await load() }
            .toolbar { toolbarContent }
            .fullScreenCoverCompat(item: $galleryStart) { start in
                GalleryView(items: start.items, startIndex: start.index, services: services)
            }
            .sheet(isPresented: $isComposingThread) {
                ReplyFormView(board: board, thread: nil) { outcome in
                    if case .threadCreated(let num) = outcome {
                        router.push(.thread(ThreadKey(board: board, threadNum: num)))
                    }
                }
            }
            .overlay { stateOverlay }
            .safeAreaInset(edge: .bottom) { pageControls }
            .task(id: sort) { await load() }
            .task(id: pageIndex) { await load() }
            .task { await loadHidden() }
            // Recomputed off the main actor whenever the board or the rules
            // change, rather than per row while drawing.
            .task(id: RuleInputs(threadNums: threads.map(\.num), rules: autohideRules)) {
                ruleHiddenNums = await PostPreview.hiddenThreadNums(
                    in: threads, onBoard: board, rules: autohideRules
                )
            }
            // Debounced by the task's own cancellation: a keystroke replaces the
            // one before it, so only the query the reader stopped on is run.
            .task(id: FilterInputs(query: searchText, threadNums: threads.map(\.num))) {
                guard !searchText.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                filteredThreads = await PostPreview.filter(threads, matching: searchText)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .list, .cards:
            List(visibleThreads) { thread in
                Group {
                    if isHidden(thread) {
                        // Shown only because the reader asked to see what is
                        // hidden. It must never look like an ordinary row, or
                        // hiding would appear to have done nothing.
                        HiddenThreadStub(
                            title: threadTitle(thread),
                            isHiddenByRule: !hiddenThreadNums.contains(thread.num)
                        ) {
                            Task { await toggleHidden(thread) }
                        }
                    } else if viewMode == .cards {
                        ThreadCardView(
                            thread: thread,
                            board: boardInfo,
                            onOpenThread: { open(thread) },
                            onOpenMedia: { openMedia($0, in: thread) }
                        )
                    } else {
                        ThreadRowView(
                            thread: thread,
                            onOpenThread: { open(thread) },
                            onOpenMedia: { openMedia($0, in: thread) }
                        )
                    }
                }
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                .swipeActions(edge: .trailing) { hideSwipeAction(for: thread) }
                .contextMenu { threadActions(for: thread) }
            }
            .listStyle(.plain)
            .scrollEdgeEffectStyle(.soft, for: .top)

        case .grid:
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(visibleThreads) { thread in
                        Group {
                            if isHidden(thread) {
                                HiddenThreadStub(
                                    title: threadTitle(thread),
                                    isHiddenByRule: !hiddenThreadNums.contains(thread.num)
                                ) {
                                    Task { await toggleHidden(thread) }
                                }
                            } else {
                                ThreadGridCell(
                                    thread: thread,
                                    onOpenThread: { open(thread) },
                                    onOpenMedia: { openMedia($0, in: thread) }
                                )
                            }
                        }
                        .contextMenu { threadActions(for: thread) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    /// Whether hidden threads come back as dimmed stubs or stay gone.
    private var hiddenThreadsBinding: Binding<Bool> {
        Binding(
            get: { services.settings.showsHiddenThreads },
            set: { services.settings.showsHiddenThreads = $0 }
        )
    }

    private func toggleBoardFavorite() async {
        isBoardFavorite = (try? await services.favorites.toggleBoard(
            board, name: boardInfo?.name ?? board
        )) ?? isBoardFavorite
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: 12)]
    }

    private var navigationTitle: String {
        boardInfo.map { "/\($0.id)/ \($0.name)" } ?? "/\(board)/"
    }

    private var visibleThreads: [ThreadSummary] {
        // Unfiltered until there is something to filter by, so a board that has
        // just loaded draws its threads on the same pass rather than flashing
        // "no threads" while the filtering task starts.
        let matching = searchText.isEmpty ? threads : filteredThreads
        guard !services.settings.showsHiddenThreads else { return matching }
        return matching.filter { !isHidden($0) }
    }

    /// Whether this thread is hidden, by the reader or by a rule.
    ///
    /// Rules are applied here as well as inside a thread: a rule that matches an
    /// opening post is meant to keep the thread off the board, which is the
    /// whole point of marking one "opening post only". Both answers are sets
    /// worked out beforehand, so this is two lookups.
    private func isHidden(_ thread: ThreadSummary) -> Bool {
        hiddenThreadNums.contains(thread.num) || ruleHiddenNums.contains(thread.num)
    }

    /// Page back and forward, shown only when the board is being read page by
    /// page. The catalog is one long list and needs none of this.
    /// Page back and forward, shown only when the board is being read page by
    /// page. The catalog is one long list and needs none of this.
    @ViewBuilder
    private var pageControls: some View {
        if !isCatalog, pageCount > 1 {
            HStack(spacing: 4) {
                pageButton(
                    systemImage: "chevron.left",
                    label: "Newer threads",
                    isEnabled: pageIndex > 0
                ) {
                    pageIndex = max(0, pageIndex - 1)
                }

                Text("Page \(pageIndex + 1) of \(pageCount)", bundle: .module)
                    .font(.footnote.monospacedDigit())
                    .accessibilityIdentifier("page-counter")
                    .frame(minWidth: 96)

                pageButton(
                    systemImage: "chevron.right",
                    label: "Older threads",
                    isEnabled: pageIndex + 1 < pageCount
                ) {
                    pageIndex = min(pageCount - 1, pageIndex + 1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(in: .capsule)
            .padding(.bottom, 8)
        }
    }

    /// One arrow of the page control.
    ///
    /// A plain `Image` in a `Button` is only as large as the glyph, which left
    /// a target of about twelve points: visible, but not reliably tappable.
    private func pageButton(
        systemImage: String,
        label: LocalizedStringKey,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 44, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if boardInfo?.allowsPosting ?? false {
            ToolbarItem(placement: .trailingBar) {
                Button {
                    isComposingThread = true
                } label: {
                    Label {
                        Text("New thread", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
        ToolbarItem(placement: .trailingBar) {
            Menu {
                Button {
                    Task { await toggleBoardFavorite() }
                } label: {
                    Label {
                        Text(isBoardFavorite ? "Unpin board" : "Pin board", bundle: .module)
                    } icon: {
                        Image(systemName: isBoardFavorite ? "star.fill" : "star")
                    }
                }
                Section {
                    Button {
                        router.push(.serverSearch(board))
                    } label: {
                        Label {
                            Text("Search this board", bundle: .module)
                        } icon: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    Button {
                        router.push(.archive(board))
                    } label: {
                        Label {
                            Text("Archive", bundle: .module)
                        } icon: {
                            Image(systemName: "archivebox")
                        }
                    }
                }
                // Always offered, so a reader who turned it on can find it
                // again. It used to appear only once something was hidden,
                // which is exactly when it is too late to notice.
                Toggle(isOn: hiddenThreadsBinding) {
                    Text("Show hidden threads", bundle: .module)
                }
                Picker(selection: viewModeBinding) {
                    Text("List", bundle: .module).tag(ThreadsViewMode.list)
                    Text("Cards", bundle: .module).tag(ThreadsViewMode.cards)
                    Text("Grid", bundle: .module).tag(ThreadsViewMode.grid)
                } label: {
                    Text("Layout", bundle: .module)
                }
                .pickerStyle(.inline)

                Toggle(isOn: catalogBinding) {
                    Text("Catalog", bundle: .module)
                }

                Picker(selection: $sort) {
                    Text("Bump order", bundle: .module).tag(CatalogSort.bumpOrder)
                    Text("Newest first", bundle: .module).tag(CatalogSort.creationDate)
                    Text("Most replies", bundle: .module).tag(CatalogSort.replyCount)
                } label: {
                    Text("Sort", bundle: .module)
                }
                .pickerStyle(.inline)
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
    private var stateOverlay: some View {
        switch loadState {
        case .loading where threads.isEmpty:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could not load /\(board)/", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            } actions: {
                Button { Task { await load() } } label: {
                    Text("Try again", bundle: .module)
                }
                .buttonStyle(.glassProminent)
            }
        case .loaded where visibleThreads.isEmpty:
            if searchText.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No threads", bundle: .module)
                    } icon: {
                        Image(systemName: "tray")
                    }
                }
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }

    /// Swiping a row hides it, which is how the Android client does it.
    @ViewBuilder
    private func hideSwipeAction(for thread: ThreadSummary) -> some View {
        Button {
            Task { await toggleHidden(thread) }
        } label: {
            Label {
                Text(isHidden(thread) ? "Unhide" : "Hide", bundle: .module)
            } icon: {
                Image(systemName: isHidden(thread) ? "eye" : "eye.slash")
            }
        }
        .tint(isHidden(thread) ? .green : .orange)
    }

    @ViewBuilder
    private func threadActions(for thread: ThreadSummary) -> some View {
        Button {
            Task { await toggleHidden(thread) }
        } label: {
            Label {
                Text(
                    hiddenThreadNums.contains(thread.num) ? "Unhide thread" : "Hide thread",
                    bundle: .module
                )
            } icon: {
                Image(systemName: hiddenThreadNums.contains(thread.num) ? "eye" : "eye.slash")
            }
        }
        Button {
            Task { await addFavorite(thread) }
        } label: {
            Label {
                Text("Add to favorites", bundle: .module)
            } icon: {
                Image(systemName: "star")
            }
        }
        if let url = DvachLinks.thread(
            board: board, threadNum: thread.num, on: services.settings.domain
        ) {
            Section {
                LinkActionsMenu(url: url, title: threadTitle(thread))
            }
        }
    }

    private func toggleHidden(_ thread: ThreadSummary) async {
        let key = ThreadKey(board: board, threadNum: thread.num)
        if hiddenThreadNums.contains(thread.num) {
            try? await services.hidden.unhideThread(key)
        } else {
            try? await services.hidden.hideThread(key, title: threadTitle(thread))
        }
        await loadHidden()
    }

    private func addFavorite(_ thread: ThreadSummary) async {
        try? await services.favorites.add(
            ThreadKey(board: board, threadNum: thread.num),
            title: threadTitle(thread),
            thumbnailPath: thread.opPost.files.first?.thumbnail
        )
    }

    private func loadHidden() async {
        hiddenThreadNums = (try? await services.hidden.hiddenThreadNums(on: board)) ?? []
        autohideRules = (try? await services.hidden.rules()) ?? []
        isBoardFavorite = (try? await services.favorites.isFavoriteBoard(board)) ?? false
    }

    private func threadTitle(_ thread: ThreadSummary) -> String {
        let subject = thread.opPost.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? "/\(board)/\(thread.num)" : subject
    }

    /// Opens the opening post's media without opening the thread.
    ///
    /// A catalog row only carries the opening post's files, so that is what the
    /// gallery shows; the rest of the thread's media is a tap away inside it.
    private func openMedia(_ attachment: NeechanAPI.Attachment, in thread: ThreadSummary) {
        let items = thread.opPost.files.map {
            GalleryItem(attachment: $0, post: thread.opPost)
        }
        guard let index = items.firstIndex(where: { $0.attachment.path == attachment.path })
        else {
            return
        }
        galleryStart = GalleryStart(items: items, index: index)
    }

    private func open(_ thread: ThreadSummary) {
        router.push(.thread(ThreadKey(board: board, threadNum: thread.num)))
    }

    private var viewModeBinding: Binding<ThreadsViewMode> {
        Binding(
            get: { viewMode },
            set: { services.settings.setThreadsViewMode($0, forBoard: board) }
        )
    }

    /// Whether this board is being read as a catalog, defaulting to the
    /// preference until the reader says otherwise on this screen.
    private var isCatalog: Bool {
        usesCatalog ?? services.settings.catalogByDefault
    }

    private var catalogBinding: Binding<Bool> {
        Binding(
            get: { isCatalog },
            set: { newValue in
                usesCatalog = newValue
                pageIndex = 0
                Task { await load() }
            }
        )
    }

    private func load() async {
        loadState = .loading
        do {
            if isCatalog {
                let page = try await services.catalog.catalog(board: board, sort: sort)
                threads = page.threads
                boardInfo = page.board
                pageCount = 1
            } else {
                let page = try await services.catalog.page(board: board, page: pageIndex)
                threads = page.summaries
                boardInfo = page.board
                pageCount = page.pageCount
            }
            loadState = .loaded
        } catch {
            loadState = .failed(error.readableMessage)
        }
    }
}

/// What the rule-hidden set depends on.
private struct RuleInputs: Equatable {
    let threadNums: [Int]
    let rules: [AutohideRuleValue]
}

/// What the filtered list depends on.
private struct FilterInputs: Equatable {
    let query: String
    let threadNums: [Int]
}
