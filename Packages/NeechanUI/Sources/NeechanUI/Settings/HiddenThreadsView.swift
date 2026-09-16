import NeechanCore
import SwiftUI

/// Everything the reader has hidden, and the way back.
///
/// Without this a thread hidden by a mis-tap is gone for good: nothing else
/// lists them, and the board only offers to bring one back if you can still
/// find it.
struct HiddenThreadsView: View {
    @Environment(AppServices.self) private var services

    @State private var items: [HiddenThreadItem] = []
    @State private var isConfirmingUnhideAll = false

    var body: some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title.isEmpty ? "/\(item.key.board)/\(item.key.threadNum)" : item.title)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(verbatim: "/\(item.key.board)/")
                        Text(item.hiddenAt, style: .date)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button {
                        Task { await unhide(item) }
                    } label: {
                        Label {
                            Text("Unhide", bundle: .module)
                        } icon: {
                            Image(systemName: "eye")
                        }
                    }
                    .tint(.green)
                }
            }
        }
        .groupedListStyle()
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nothing hidden", bundle: .module)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                } description: {
                    Text("Threads you hide on a board are listed here.", bundle: .module)
                }
            }
        }
        .navigationTitle(Text("Hidden threads", bundle: .module))
        .inlineNavigationTitle()
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .trailingBar) {
                    Button {
                        isConfirmingUnhideAll = true
                    } label: {
                        Text("Unhide all", bundle: .module)
                    }
                }
            }
        }
        .confirmationDialog(
            Text("Bring every hidden thread back?", bundle: .module),
            isPresented: $isConfirmingUnhideAll,
            titleVisibility: .visible
        ) {
            Button {
                Task {
                    try? await services.hidden.unhideAllThreads()
                    await reload()
                }
            } label: {
                Text("Unhide all", bundle: .module)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        items = (try? await services.hidden.hiddenThreads()) ?? []
    }

    private func unhide(_ item: HiddenThreadItem) async {
        try? await services.hidden.unhideThread(item.key)
        await reload()
    }
}
