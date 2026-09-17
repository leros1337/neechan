import NeechanCore
import SwiftUI

/// Threads kept on the device, readable with no network.
struct SavedThreadsView: View {
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router

    @State private var items: [SavedThreadItem] = []
    @State private var isConfirmingClear = false

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    router.push(.savedThread(item.key))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? "/\(item.key.board)/\(item.key.threadNum)" : item.title)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        HStack(spacing: 10) {
                            Text(verbatim: "/\(item.key.board)/")
                            Text("\(item.postsCount) posts", bundle: .module)
                            if item.includesFiles {
                                Label {
                                    Text("Files", bundle: .module)
                                } icon: {
                                    Image(systemName: "photo")
                                }
                            }
                            Text(Int64(item.bytesOnDisk).formatted(.byteCount(style: .file)))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(item.savedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await remove(item) }
                    } label: {
                        Label {
                            Text("Delete", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .groupedListStyle()
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nothing saved", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                } description: {
                    Text("Save a thread from its menu to read it without a connection.", bundle: .module)
                }
            }
        }
        .navigationTitle(Text("Saved threads", bundle: .module))
        .inlineNavigationTitle()
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .trailingBar) {
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Text("Delete all", bundle: .module)
                    }
                }
            }
        }
        .confirmationDialog(
            Text("Delete every saved thread?", bundle: .module),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    try? await services.savedThreads.removeAll(site: services.site)
                    await reload()
                }
            } label: {
                Text("Delete", bundle: .module)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        items = (try? await services.savedThreads.saved(site: services.site)) ?? []
    }

    private func remove(_ item: SavedThreadItem) async {
        try? await services.savedThreads.remove(item.key)
        await reload()
    }
}
