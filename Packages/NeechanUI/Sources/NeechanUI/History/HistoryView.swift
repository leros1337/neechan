import NeechanCore
import SwiftUI

/// Threads the reader has opened, most recent first.
public struct HistoryView: View {
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var items: [HistoryItem] = []
    @State private var searchText = ""

    public init() {}

    public var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    router.push(.thread(item.key))
                } label: {
                    HistoryRow(item: item)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await remove(item) }
                    } label: {
                        Label {
                            Text("Remove", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $searchText, prompt: Text("Search history", bundle: .module))
        .navigationTitle(Text("History", bundle: .module))
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .trailingBar) {
                    Button(role: .destructive) {
                        Task { await clear() }
                    } label: {
                        Text("Clear", bundle: .module)
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No history yet", bundle: .module)
                    } icon: {
                        Image(systemName: "clock")
                    }
                } description: {
                    Text("Threads you open are listed here.", bundle: .module)
                }
            }
        }
        .task(id: searchText) { await load() }
    }

    private func load() async {
        items = (try? await services.history.search(searchText, limit: 200)) ?? []
    }

    private func remove(_ item: HistoryItem) async {
        try? await services.history.remove(item.key)
        await load()
    }

    private func clear() async {
        try? await services.history.clear()
        await load()
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(verbatim: "/\(item.key.board)/")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tint)
                    Text(item.visitedAt, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
