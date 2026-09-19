import NeechanCore
import NeechanSettings
import SwiftUI

/// How posts are drawn: size, density, and colour.
struct InterfaceSettingsView: View {
    @Environment(AppServices.self) private var services
    /// The icon on the home screen, as the system reports it.
    @State private var iconChoice: AppIconChoice = .original
    /// Set when the system refused to change it.
    @State private var iconFailed = false

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Picker(selection: $settings.appearance) {
                    Text("System", bundle: .module).tag(AppearanceMode.system)
                    Text("Light", bundle: .module).tag(AppearanceMode.light)
                    Text("Dark", bundle: .module).tag(AppearanceMode.dark)
                } label: {
                    Text("Appearance", bundle: .module)
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    ThemesView()
                } label: {
                    Label {
                        Text("Theme", bundle: .module)
                    } icon: {
                        Image(systemName: "paintpalette")
                    }
                }
            }

            if AppIconSwitcher.isSupported {
                Section {
                    // Side by side rather than a row each: the icons as full
                    // rows took more of the screen than the setting is worth,
                    // and the choice is a picture, so it reads fine small.
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(AppIconChoice.available()) { choice in
                            iconTile(choice)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("App icon", bundle: .module)
                } footer: {
                    if iconFailed {
                        Text("The icon could not be changed.", bundle: .module)
                    } else {
                        Text("Changing it takes a moment to show on the home screen.", bundle: .module)
                    }
                }
            }

            Section {
                scaleSlider(
                    title: "Text size",
                    identifier: "text-scale",
                    value: Binding(
                        get: { services.settings.textScale },
                        set: { services.settings.textScale = $0 }
                    )
                )
                scaleSlider(
                    title: "Thumbnail size",
                    identifier: "thumbnail-scale",
                    value: Binding(
                        get: { services.settings.thumbnailScale },
                        set: { services.settings.thumbnailScale = $0 }
                    )
                )
            } header: {
                Text("Size", bundle: .module)
            } footer: {
                Text("These multiply whatever size the system is already using.", bundle: .module)
            }

            Section {
                Stepper(value: $settings.collapsePostLineLimit, in: 3...60) {
                    Text(
                        "Collapse after \(services.settings.collapsePostLineLimit) lines",
                        bundle: .module
                    )
                }
                Toggle(isOn: $settings.showsHiddenThreads) {
                    Text("Show hidden threads", bundle: .module)
                }
            } header: {
                Text("Posts", bundle: .module)
            } footer: {
                Text(
                    "Showing hidden threads brings them back as dimmed one-line rows you can tap to restore.",
                    bundle: .module
                )
            }
        }
        .navigationTitle(Text("Appearance", bundle: .module))
        .inlineNavigationTitle()
        // Asked of the system rather than remembered: the reader can change the
        // icon from elsewhere, and what is on the home screen is the truth.
        .task {
            iconChoice = AppIconSwitcher.current
            iconFailed = false
        }
    }

    /// One icon, ringed when it is the one in use.
    ///
    /// A ring rather than a tick: at this size the tick would sit on top of the
    /// picture it is meant to be marking.
    @ViewBuilder
    private func iconTile(_ choice: AppIconChoice) -> some View {
        let isChosen = choice == iconChoice

        Button {
            choose(choice)
        } label: {
            VStack(spacing: 6) {
                if let preview = Image(iconPreview: choice) {
                    preview
                        .resizable()
                        .frame(width: 52, height: 52)
                        // The same shape the home screen gives it, so the tile
                        // shows what the reader will actually get.
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isChosen ? AnyShapeStyle(.tint)
                                                       : AnyShapeStyle(.clear),
                                              lineWidth: 2)
                        }
                }

                Text(choice.title, bundle: .module)
                    .font(.caption)
                    .foregroundStyle(isChosen ? AnyShapeStyle(.tint)
                                              : AnyShapeStyle(.secondary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("app-icon-\(choice.rawValue)")
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private func choose(_ choice: AppIconChoice) {
        guard choice != iconChoice else { return }
        Task {
            let changed = await AppIconSwitcher.apply(choice)
            iconFailed = !changed
            guard changed else { return }
            iconChoice = choice
            // Kept so the screen can draw the choice before asking the system,
            // and so anything else that wants to know need not.
            services.settings.appIconName = choice.alternateName
        }
    }

    private func scaleSlider(
        title: LocalizedStringKey,
        identifier: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title, bundle: .module)
                Spacer()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0.75...2, step: 0.05)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text(title, bundle: .module))
        }
    }
}
