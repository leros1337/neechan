import NeechanCore
import SwiftUI

/// Preferences that are about the app rather than the site.
struct GeneralSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var isClearingHistory = false

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Picker(selection: $settings.languageCode) {
                    Text("System", bundle: .module).tag(String?.none)
                    Text(verbatim: "English").tag(String?.some("en"))
                    Text(verbatim: "Русский").tag(String?.some("ru"))
                } label: {
                    Text("Language", bundle: .module)
                }
                .accessibilityIdentifier("language-picker")
            } footer: {
                Text("The site's own text stays in the language it was written in.", bundle: .module)
            }

            Section {
                Toggle(isOn: $settings.remembersHistory) {
                    Text("Remember opened threads", bundle: .module)
                }
                Button(role: .destructive) {
                    isClearingHistory = true
                } label: {
                    Text("Clear history", bundle: .module)
                }
            } header: {
                Text("History", bundle: .module)
            } footer: {
                Text("Turning this off stops new threads being recorded.", bundle: .module)
            }

            Section {
                Toggle(isOn: $settings.usesInternalBrowser) {
                    Text("Open links in the app", bundle: .module)
                }
            } footer: {
                Text("Links outside 2ch open in a browser sheet instead of Safari.", bundle: .module)
            }
        }
        .onChange(of: services.settings.remembersHistory) {
            services.applyHistoryRecordingSetting()
        }
        .navigationTitle(Text("General", bundle: .module))
        .inlineNavigationTitle()
        .confirmationDialog(
            Text("Clear all history?", bundle: .module),
            isPresented: $isClearingHistory,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { try? await services.history.clear() }
            } label: {
                Text("Clear", bundle: .module)
            }
        }
    }
}
