import NeechanAPI
import NeechanCore
import SwiftUI

/// Preferences about the site: which mirror and which board.
struct ForumSettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var defaultBoard = ""

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Picker(selection: $settings.domain) {
                    ForEach(DvachDomain.allCases, id: \.self) { domain in
                        Text(domain.rawValue).tag(domain)
                    }
                } label: {
                    Text("Mirror", bundle: .module)
                }
            } footer: {
                Text(
                    "Both mirrors serve the same content. Your passcode and age confirmation move with you.",
                    bundle: .module
                )
            }

            Section {
                TextField(text: $defaultBoard) {
                    Text("Board code, such as b", bundle: .module)
                }
                .noAutocapitalization()
                .autocorrectionDisabled()
                .onSubmit(saveDefaultBoard)

                Toggle(isOn: $settings.catalogByDefault) {
                    Text("Open boards as the catalog", bundle: .module)
                }
            } header: {
                Text("Default board", bundle: .module)
            } footer: {
                Text("The catalog shows every thread at once instead of page by page.", bundle: .module)
            }

            Section {
                NavigationLink {
                    PasscodeLoginView()
                } label: {
                    Label {
                        Text("Passcode", bundle: .module)
                    } icon: {
                        Image(systemName: "key")
                    }
                }
                NavigationLink {
                    CookiesManagerView()
                } label: {
                    Label {
                        Text("Cookies", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                    }
                }
            }
        }
        .navigationTitle(Text("Forum", bundle: .module))
        .inlineNavigationTitle()
        .onAppear {
            defaultBoard = services.settings.defaultBoard ?? ""
        }
        .onDisappear(perform: saveDefaultBoard)
        .onChange(of: services.settings.domain) {
            Task { await services.handleDomainChange() }
        }
    }

    private func saveDefaultBoard() {
        let code = defaultBoard
            .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            .lowercased()
        services.settings.defaultBoard = code.isEmpty ? nil : code
        defaultBoard = code
    }
}
