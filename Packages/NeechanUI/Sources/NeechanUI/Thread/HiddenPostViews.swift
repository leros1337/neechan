import NeechanAPI
import NeechanCore
import SwiftData
import SwiftUI

/// Stands in for a post a rule hid.
///
/// Kept in place rather than removed so a reply to it still makes sense, and so
/// the reader can look at what was hidden without undoing the rule.
struct HiddenPostStub: View {
    let post: Post
    let indexInThread: Int?
    var onReveal: () -> Void

    var body: some View {
        Button(action: onReveal) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let indexInThread {
                    Text(verbatim: "\(indexInThread)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text("Hidden post", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(verbatim: "№\(post.num)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows this post", bundle: .module))
    }
}

/// The rules hiding posts in this thread, so they can be undone.
struct HiddenPostsSheet: View {
    let thread: ThreadKey
    var onChange: () async -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []

    private struct Entry: Identifiable {
        let id: PersistentIdentifier
        let rule: LocalHideRule
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: entry.rule))
                            .foregroundStyle(.secondary)
                        description(for: entry.rule)
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await remove(entry) }
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
            .navigationTitle(Text("Hidden posts", bundle: .module))
            .inlineNavigationTitle()
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Nothing hidden here", bundle: .module)
                        } icon: {
                            Image(systemName: "eye")
                        }
                    } description: {
                        Text("Hide a post from its menu to add a rule.", bundle: .module)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func icon(for rule: LocalHideRule) -> String {
        switch rule {
        case .post: "eye.slash"
        case .repliesTree: "arrow.trianglehead.branch"
        case .name: "person.slash"
        case .similar: "doc.on.doc"
        }
    }

    private func description(for rule: LocalHideRule) -> Text {
        switch rule {
        case .post(let num):
            Text("Post №\(num)", bundle: .module)
        case .repliesTree(let num):
            Text("Post №\(num) and its replies", bundle: .module)
        case .name(let name):
            Text("Posts by \(name)", bundle: .module)
        case .similar:
            Text("Posts similar to a hidden one", bundle: .module)
        }
    }

    private func load() async {
        entries = ((try? await services.hidden.localRuleEntries(in: thread)) ?? [])
            .map { Entry(id: $0.id, rule: $0.rule) }
    }

    private func remove(_ entry: Entry) async {
        try? await services.hidden.removeLocalRule(id: entry.id)
        await load()
        await onChange()
    }
}

/// Separates the posts the reader has already seen from the new ones.
struct NewPostsDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Text("New posts", bundle: .module)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(.tint.opacity(0.35))
            .frame(height: 1)
    }
}
