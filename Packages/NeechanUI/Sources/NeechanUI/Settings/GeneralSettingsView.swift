import NeechanCore
import SwiftUI

/// Preferences that are about the app rather than the site.
struct GeneralSettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppLock.self) private var lock
    @State private var isClearingHistory = false
    /// Whether the device has any way of asking who is holding it.
    @State private var canLock = true

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
                Toggle(isOn: $settings.locksApp) {
                    Text("Lock the app", bundle: .module)
                }
                .disabled(!canLock)
                .accessibilityIdentifier("app-lock-toggle")
            } header: {
                Text("Privacy", bundle: .module)
            } footer: {
                if canLock {
                    Text(
                        "Asks for Face ID, Touch ID or your device passcode when you come back after a minute away, and every time the app is opened fresh.",
                        bundle: .module
                    )
                } else {
                    Text("Set a passcode on this device to use this.", bundle: .module)
                }
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
        .onChange(of: services.settings.locksApp) { _, isOn in
            lock.setEnabled(isOn)
        }
        // Checked on every visit rather than once: the reader may have gone to
        // the device's own settings to give it a passcode and come back.
        .task {
            canLock = lock.canLock()
            // A device that has lost its passcode cannot be asked anything, and
            // the switch would promise something nothing can deliver.
            if !canLock, services.settings.locksApp {
                services.settings.locksApp = false
            }
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
