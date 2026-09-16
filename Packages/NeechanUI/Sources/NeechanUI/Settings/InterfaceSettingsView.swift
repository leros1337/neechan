import NeechanCore
import NeechanSettings
import SwiftUI

/// How posts are drawn: size, density, and colour.
struct InterfaceSettingsView: View {
    @Environment(AppServices.self) private var services

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
                Toggle(isOn: $settings.safeForWork) {
                    Text("Safe for work", bundle: .module)
                }
                Toggle(isOn: $settings.showsHiddenThreads) {
                    Text("Show hidden threads", bundle: .module)
                }
            } header: {
                Text("Posts", bundle: .module)
            } footer: {
                Text(
                    "Safe for work blurs every thumbnail until it is tapped. Showing hidden threads brings them back as dimmed one-line rows you can tap to restore.",
                    bundle: .module
                )
            }
        }
        .navigationTitle(Text("Appearance", bundle: .module))
        .inlineNavigationTitle()
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
