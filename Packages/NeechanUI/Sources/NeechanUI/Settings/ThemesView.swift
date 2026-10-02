import NeechanAPI
import NeechanCore
import SwiftUI

/// Picks a colour scheme, and makes new ones from colours the reader picks.
struct ThemesView: View {
    @Environment(AppServices.self) private var services

    @State private var themes: [NeechanTheme] = [.builtIn]
    @State private var isCreating = false
    @State private var message: AlertMessage?

    var body: some View {
        List {
            ForEach(themes) { theme in
                Button {
                    services.settings.themeID = theme.id
                } label: {
                    HStack(spacing: 12) {
                        ThemeSwatch(theme: theme)
                        // The name alone. A "Dark" or "Light" under it read as
                        // what picking the theme would do, but light or dark is
                        // the Appearance setting's to decide, not the theme's.
                        Text(theme.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if isSelected(theme) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                // Without this the row's text takes the tint, which on this
                // screen is the very colour the row is offering to change.
                .buttonStyle(.plain)
                .swipeActions {
                    if !theme.isBuiltIn {
                        Button(role: .destructive) {
                            Task { await remove(theme) }
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
        }
        .groupedListStyle()
        .navigationTitle(Text("Theme", bundle: .module))
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                // A palette rather than a file: a theme here is two colours,
                // and asking for a Dashchan file to get them sent the reader to
                // Files for something they could simply have picked.
                Button {
                    isCreating = true
                } label: {
                    Label {
                        Text("Add theme", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .accessibilityIdentifier("themes-add")
            }
        }
        .sheet(isPresented: $isCreating) {
            NewThemeView(startingFrom: selectedTheme) { theme in
                Task { await keep(theme) }
            }
        }
        .alert(item: $message) { message in
            Alert(title: Text(message.text))
        }
        .task { await reload() }
    }

    /// Nothing chosen means the shipped scheme, so that row reads as selected
    /// on a fresh install rather than leaving the list with no checkmark.
    private func isSelected(_ theme: NeechanTheme) -> Bool {
        (services.settings.themeID ?? NeechanTheme.builtIn.id) == theme.id
    }

    /// The theme in use, which a new one starts from.
    private var selectedTheme: NeechanTheme {
        themes.first(where: isSelected) ?? .builtIn
    }

    private func reload() async {
        themes = (try? await services.themes.themes()) ?? [.builtIn]
    }

    private func remove(_ theme: NeechanTheme) async {
        if isSelected(theme) { services.settings.themeID = NeechanTheme.builtIn.id }
        try? await services.themes.remove(id: theme.id)
        await reload()
    }

    /// Keeps a theme the reader made, and puts it on.
    private func keep(_ theme: NeechanTheme) async {
        do {
            try await services.themes.add(theme)
            services.settings.themeID = theme.id
            await reload()
        } catch {
            message = AlertMessage(
                text: String(localized: "The theme could not be saved.", bundle: .module.forAppLanguage(), locale: AppLocale.current)
            )
        }
    }
}

/// A small preview of a theme's colours.
struct ThemeSwatch: View {
    let theme: NeechanTheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(theme.background))
            .overlay {
                HStack(spacing: 3) {
                    Circle().fill(Color(theme.accent))
                    Circle().fill(Color(theme.postText))
                    Circle().fill(Color(theme.quote))
                }
                .padding(6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            }
            .frame(width: 44, height: 32)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// A theme colour as SwiftUI sees it.
    init(_ colour: ThemeColor) {
        self.init(
            .sRGB,
            red: colour.red,
            green: colour.green,
            blue: colour.blue,
            opacity: colour.opacity
        )
    }
}

extension ThemeColor {
    /// A colour picked in the palette, as a theme keeps it.
    ///
    /// Read as sRGB, the space `Color(_: ThemeColor)` draws in, so a colour
    /// saved from the picker looks the same when the theme is next used. A
    /// wide-gamut pick can fall outside it, and is kept to the edge.
    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        #if canImport(UIKit)
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #elseif canImport(AppKit)
        if let srgb = NSColor(color).usingColorSpace(.sRGB) {
            srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        #endif
        func clamped(_ value: CGFloat) -> Double { min(1, max(0, Double(value))) }
        self.init(red: clamped(red), green: clamped(green), blue: clamped(blue), opacity: clamped(alpha))
    }
}
