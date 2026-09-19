import NeechanCore
import SwiftUI

/// Rules that hide posts across every thread.
public struct AutohideRulesView: View {
    @Environment(AppServices.self) private var services
    @State private var rules: [AutohideRuleValue] = []
    @State private var editing: AutohideRuleValue?

    public init() {}

    public var body: some View {
        List {
            ForEach(rules) { rule in
                Button {
                    editing = rule
                } label: {
                    AutohideRuleRow(rule: rule)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await remove(rule) }
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
        .navigationTitle(Text("Autohide", bundle: .module))
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button {
                    editing = AutohideRuleValue(pattern: "", matchesComment: true)
                } label: {
                    Label {
                        Text("New rule", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No rules yet", bundle: .module)
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                } description: {
                    Text(
                        "A rule hides every post matching it, on every board unless you narrow it.",
                        bundle: .module
                    )
                }
            }
        }
        .sheet(item: $editing) { rule in
            AutohideRuleEditor(rule: rule) { saved in
                Task { await save(saved) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        rules = (try? await services.hidden.rules()) ?? []
    }

    private func save(_ rule: AutohideRuleValue) async {
        if rules.contains(where: { $0.id == rule.id }) {
            try? await services.hidden.updateRule(rule)
        } else {
            try? await services.hidden.addRule(rule)
        }
        await load()
    }

    private func remove(_ rule: AutohideRuleValue) async {
        try? await services.hidden.removeRule(id: rule.id)
        await load()
    }
}

private struct AutohideRuleRow: View {
    let rule: AutohideRuleValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.pattern.isEmpty ? "—" : rule.pattern)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)

            HStack(spacing: 6) {
                if rule.isRegularExpression {
                    Tag(text: Text(verbatim: ".*"))
                }
                if rule.matchesComment { Tag(text: Text("Comment", bundle: .module)) }
                if rule.matchesSubject { Tag(text: Text("Subject", bundle: .module)) }
                if rule.matchesName { Tag(text: Text("Name", bundle: .module)) }
                if rule.matchesFileName { Tag(text: Text("File", bundle: .module)) }
                if !rule.boards.isEmpty {
                    Tag(text: Text(verbatim: rule.boards.sorted().map { "/\($0)/" }.joined(separator: " ")))
                }
            }
        }
        .contentShape(.rect)
    }

    private struct Tag: View {
        let text: Text

        var body: some View {
            text
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
                .foregroundStyle(.secondary)
        }
    }
}

/// Writes one rule, checking the pattern as it is typed.
struct AutohideRuleEditor: View {
    @State private var rule: AutohideRuleValue
    @State private var testText = ""
    private let onSave: (AutohideRuleValue) -> Void

    @Environment(\.dismiss) private var dismiss

    init(rule: AutohideRuleValue, onSave: @escaping (AutohideRuleValue) -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        text: $rule.pattern,
                        prompt: Text("Text to hide", bundle: .module),
                        axis: .vertical
                    ) {
                        Text("Pattern", bundle: .module)
                    }
                    .noAutocapitalization()
                    .autocorrectionDisabled()

                    Toggle(isOn: $rule.isRegularExpression) {
                        Text("Regular expression", bundle: .module)
                    }
                } footer: {
                    if let error = rule.patternError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle(isOn: $rule.matchesComment) { Text("Comment", bundle: .module) }
                    Toggle(isOn: $rule.matchesSubject) { Text("Subject", bundle: .module) }
                    Toggle(isOn: $rule.matchesName) { Text("Name", bundle: .module) }
                    Toggle(isOn: $rule.matchesFileName) { Text("File name", bundle: .module) }
                } header: {
                    Text("Look in", bundle: .module)
                } footer: {
                    Text("A rule with nothing selected never matches.", bundle: .module)
                }

                Section {
                    Toggle(isOn: $rule.appliesToOriginalPostOnly) {
                        Text("Opening posts only", bundle: .module)
                    }
                    Toggle(isOn: $rule.appliesToSagedOnly) {
                        Text("Saged posts only", bundle: .module)
                    }
                    Toggle(isOn: $rule.isEnabled) {
                        Text("Enabled", bundle: .module)
                    }
                }

                Section {
                    TextField(
                        text: $testText,
                        prompt: Text("Paste text to check", bundle: .module),
                        axis: .vertical
                    ) {
                        Text("Test", bundle: .module)
                    }
                    .noAutocapitalization()
                    .autocorrectionDisabled()

                    // Checking against real text is the only way to be sure a
                    // rule does what was meant before it starts hiding things.
                    if !testText.isEmpty {
                        Label {
                            matches
                                ? Text("This text would be hidden", bundle: .module)
                                : Text("This text would not be hidden", bundle: .module)
                        } icon: {
                            Image(systemName: matches ? "eye.slash.fill" : "eye")
                        }
                        .font(.footnote)
                        .foregroundStyle(matches ? .red : .secondary)
                    }
                } header: {
                    Text("Try it", bundle: .module)
                }
            }
            .navigationTitle(Text("Rule", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label {
                            Text("Cancel", bundle: .module)
                        } icon: {
                            Image(systemName: "xmark")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(rule)
                        dismiss()
                    } label: {
                        Label {
                            Text("Done", bundle: .module)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(!rule.isUsable && rule.isEnabled)
                }
            }
        }
    }

    private var matches: Bool {
        AutohideRulePreview.matches(rule, text: testText)
    }
}
