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
            titleRow

            // The board filter doubles as the app's "go to" field: a post
            // number, a board code or a pasted link all resolve here, which is
            // what the separate search tab used to be for.
            if let target = navigationTarget {
                Section {
                    if services.contentPolicy.allowsOpening(target) {
                        Button {
                            router.open(target)
                            searchText = ""
                        } label: {
                            DestinationRow(target: target)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("go-to")
                    } else {
                        // `Router` refuses this too, but it does so silently.
                        // A typed code that simply does nothing reads as a
                        // broken field, so the reason belongs here — and so
                        // does the way through, since the reader is one tap
                        // from being allowed in.
                        Button {
                            router.openRestrictions()
                        } label: {
                            Label {
                                Text("For adults. Turn on Adult 18+ to open it.", bundle: .module)
                            } icon: {
                                Image(systemName: "hand.raised")
                            }
                        }
                        .accessibilityIdentifier("go-to-restricted")
                    }
                } header: {
                    Text("Go to", bundle: .module)
                }
            }

            // Shown whatever the age gate says, like every board below: every
            // board a 2ch reader made is for adults, so the route behind this
            // is refused on the way in, where it offers the way through. The
            // App Store build lists no user boards at all, so there the row
            // would lead to an empty screen.
            if searchText.isEmpty,
                services.capabilities.userBoards,
                services.contentPolicy.listsEveryBoard {
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
                        // A board for adults is listed but not opened. The tap
                        // has to go somewhere: `Router.push` refuses silently,
                        // which from the reader's side is a row that does
                        // nothing, so the age gate is what it opens instead.
                        let isGated = !services.contentPolicy
                            .allowsOpening(code: board.id, on: services.site)
                        Button {
                            if isGated {
                                router.openRestrictions()
                            } else {
                                router.push(.board(board.id))
                            }
                        } label: {
                            BoardRow(board: board, isGated: isGated)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            isGated ? "board-gated-\(board.id)" : "board-\(board.id)"
                        )
                    }
                }
            }
        }
        .groupedListStyle()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $searchText)
        // The title is drawn in the list rather than by the navigation bar, so
        // it can share its line with the switcher. Still set, and still
        // inline, so the bar keeps its name for the accessibility tree and for
        // anything that reads a screen's title — it simply draws nothing while
        // this screen is the one on top.
        // No navigation title: this screen draws its own, in the list, so that
        // it can share its line with the switcher. Setting one as well puts the
        // same word on screen twice — `toolbar(removing: .title)` does not take
        // it off a large title, and an inline one simply moves the duplicate
        // into the bar. Nothing is lost by leaving it out: every screen pushed
        // from here comes back through a plain chevron, which is what iOS 26
        // draws whether the previous screen named itself or not.
        .refreshable { await load(forceRefresh: true) }
        .overlay { stateOverlay }
        // Keyed on the imageboard, not merely "load once": the list held
        // whatever it had, so switching sites left the old site's boards on
        // screen until something else happened to reload them.
        .task(id: services.site) {
            if categories.isEmpty { loadState = .loading }
            await load()
        }
    }

    /// The screen's title, with the imageboard switcher on the same line.
    ///
    /// Drawn here rather than by the navigation bar because the bar cannot put
    /// anything beside a large title: `ToolbarItemPlacement.largeTitle` renders
    /// its content but creates no element at all — a plain `Button` placed
    /// there is missing from the accessibility tree and never receives a tap.
    /// Verified by dumping a running app's hierarchy; a `.topBarTrailing` probe
    /// beside it appears exactly as expected.
    ///
    /// A segmented control rather than a menu: there are two sites and readers
    /// flip between them, so one tap beats two and the one in use is visible
    /// without opening anything.
    @ViewBuilder
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Boards", bundle: .module)
                .font(.largeTitle.weight(.bold))
            Spacer(minLength: 12)
            Picker(selection: siteBinding) {
                // Proper nouns, so `verbatim`: they are not translated, and the
                // catalog test would otherwise ask for a Russian "4chan".
                ForEach(Imageboard.allCases) { site in
                    Text(verbatim: site.displayName).tag(site)
                }
            } label: {
                Text("Imageboard", bundle: .module)
            }
            .pickerStyle(.segmented)
            // Sized to its two names: left to itself a segmented picker takes
            // every point of the row it is given.
            .fixedSize()
            .accessibilityIdentifier("imageboard-picker")
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// Written straight to settings; the switch itself is handled once, on the
    /// shell, because the same change can come from three different places.
    private var siteBinding: Binding<Imageboard> {
        Binding(
            get: { services.settings.imageboard },
            // Through `select` rather than straight to settings: it re-points
            // the client before the new value is observable, which is what lets
            // this list reload against the site the reader just chose.
            set: { services.select($0) }
        )
    }

    /// The destination the query resolves to, if it is one.
    private var navigationTarget: NavigationTarget? {
        NavigationQueryParser.parse(
            searchText,
            site: services.site,
            currentBoard: services.settings.defaultBoard
        )
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
    /// Listed, but behind the age gate: marked so the reader knows the tap
    /// leads to the switch rather than to the board.
    var isGated: Bool = false

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
            Image(systemName: isGated ? "hand.raised.fill" : "chevron.forward")
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
        case .board(let board): board.displayCode
        case .thread(let key): key.description
        case .threadAtPost(let key, let postNum): "\(key.description) → \(postNum)"
        case .post(let board, let num): "\(board.displayCode) №\(num)"
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
