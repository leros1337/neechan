import NeechanAPI
import NeechanCore
import SwiftUI

/// Makes a theme from two colours the reader picks.
///
/// The system's palette does the picking — a grid, a spectrum and sliders — so
/// any colour at all can be had. The two are what a built-in theme sets: the
/// accent, which tints the app and its links, and the colour of quotes.
struct NewThemeView: View {
    /// Called with the theme when the reader saves it.
    var onSave: (NeechanTheme) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var accent: Color
    @State private var quote: Color

    /// - Parameter theme: the one in use, so the palette opens on colours the
    ///   reader already knows rather than on black.
    init(startingFrom theme: NeechanTheme, onSave: @escaping (NeechanTheme) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: String(localized: "My theme", bundle: .module.forAppLanguage(), locale: AppLocale.current))
        _accent = State(initialValue: Color(theme.accent))
        _quote = State(initialValue: Color(theme.quote))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) {
                        Text("Name", bundle: .module)
                    }
                    .accessibilityIdentifier("new-theme-name")
                }

                Section {
                    ColorPicker(selection: $accent, supportsOpacity: false) {
                        Text("Accent", bundle: .module)
                    }
                    .accessibilityIdentifier("new-theme-accent")
                    ColorPicker(selection: $quote, supportsOpacity: false) {
                        Text("Quotes", bundle: .module)
                    }
                    .accessibilityIdentifier("new-theme-quote")
                }

                Section {
                    preview
                }
            }
            .navigationTitle(Text("New theme", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Cancel", bundle: .module)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(theme)
                        dismiss()
                    } label: {
                        Text("Save", bundle: .module)
                    }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("new-theme-save")
                }
            }
        }
    }

    /// The theme as it stands, in the colours picked so far.
    private var theme: NeechanTheme {
        .custom(name: trimmedName, accent: ThemeColor(accent), quote: ThemeColor(quote))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a post will look like: a quote and a link, in the chosen colours.
    private var preview: some View {
        HStack(spacing: 12) {
            ThemeSwatch(theme: theme)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ">greentext")
                    .foregroundStyle(quote)
                Text(verbatim: ">>123456")
                    .foregroundStyle(accent)
                    .underline()
            }
            .font(.callout)
        }
        .accessibilityHidden(true)
    }
}
