import SwiftUI

/// A search field drawn by the app, for where the system's cannot be used.
///
/// Only an iPad app running on a Mac needs it: see `appSearchable`. It does
/// what the system field does there that a reader would miss — a magnifying
/// glass, a clear button, Escape to clear, and Return to submit.
struct InlineSearchField: View {
    @Binding var text: String
    var prompt: Text?
    var isFocused: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?

    /// Whether this stands in for the system's field in this process.
    static var isNeeded: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear", bundle: .module))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var field: some View {
        let field = TextField(text: $text, prompt: prompt) { prompt ?? Text("Search", bundle: .module) }
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit { onSubmit?() }
            .onKeyPress(.escape) {
                guard !text.isEmpty else { return .ignored }
                text = ""
                return .handled
            }
        if let isFocused {
            field.focused(isFocused)
        } else {
            field
        }
    }
}
