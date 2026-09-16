import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Picks a colour scheme, and takes in theme files exported from Dashchan.
struct ThemesView: View {
    @Environment(AppServices.self) private var services

    @State private var themes: [NeechanTheme] = [.builtIn]
    @State private var isImporting = false
    @State private var message: AlertMessage?

    var body: some View {
        List {
            ForEach(themes) { theme in
                Button {
                    services.settings.themeID = theme.id
                } label: {
                    HStack(spacing: 12) {
                        ThemeSwatch(theme: theme)
                        VStack(alignment: .leading) {
                            Text(theme.name)
                                .foregroundStyle(.primary)
                            Text(
                                theme.isDark ? "Dark" : "Light",
                                bundle: .module
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
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
                Button {
                    isImporting = true
                } label: {
                    Label {
                        Text("Import theme", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .jsonFileImporter(isPresented: $isImporting) { url in
            Task { await runImport(from: url) }
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

    private func reload() async {
        themes = (try? await services.themes.themes()) ?? [.builtIn]
    }

    private func remove(_ theme: NeechanTheme) async {
        if isSelected(theme) { services.settings.themeID = NeechanTheme.builtIn.id }
        try? await services.themes.remove(id: theme.id)
        await reload()
    }

    private func runImport(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let theme = try await services.themes.import(Data(contentsOf: url))
            services.settings.themeID = theme.id
            await reload()
        } catch {
            message = AlertMessage(
                text: String(localized: "That file is not a theme.", bundle: .module, locale: AppLocale.current)
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
