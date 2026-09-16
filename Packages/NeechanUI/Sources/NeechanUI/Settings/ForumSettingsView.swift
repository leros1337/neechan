import NeechanAPI
import NeechanCore
import SwiftUI

/// Preferences about the site: which mirror, which board, and how the app
/// reaches it.
struct ForumSettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var defaultBoard = ""
    @State private var proxyHost = ""
    @State private var proxyPort = ""

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

            Section {
                TextField(text: $proxyHost) {
                    Text("Host", bundle: .module)
                }
                .noAutocapitalization()
                .autocorrectionDisabled()

                TextField(text: $proxyPort) {
                    Text("Port", bundle: .module)
                }
                .numericKeyboard()

                Button(action: saveProxy) {
                    Text("Apply proxy", bundle: .module)
                }
                .disabled(proxyIsUnchanged)
            } header: {
                Text("Proxy", bundle: .module)
            } footer: {
                Text("Leave the host empty to connect directly.", bundle: .module)
            }
        }
        .navigationTitle(Text("Forum", bundle: .module))
        .inlineNavigationTitle()
        .onAppear {
            defaultBoard = services.settings.defaultBoard ?? ""
            proxyHost = services.settings.proxyHost ?? ""
            proxyPort = services.settings.proxyPort > 0
                ? String(services.settings.proxyPort)
                : ""
        }
        .onDisappear(perform: saveDefaultBoard)
        .onChange(of: services.settings.domain) {
            Task { await services.handleDomainChange() }
        }
    }

    private var proxyIsUnchanged: Bool {
        let host = proxyHost.trimmingCharacters(in: .whitespaces)
        let port = Int(proxyPort) ?? 0
        return host == (services.settings.proxyHost ?? "")
            && port == services.settings.proxyPort
    }

    private func saveDefaultBoard() {
        let code = defaultBoard
            .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            .lowercased()
        services.settings.defaultBoard = code.isEmpty ? nil : code
        defaultBoard = code
    }

    /// A proxy only takes effect on connections made afterwards, so the cached
    /// boards and threads are dropped along with it.
    private func saveProxy() {
        services.settings.proxyHost = proxyHost
        services.settings.proxyPort = Int(proxyPort) ?? 0
        Task { await services.applyProxySettings() }
    }
}

extension View {
    /// A number pad where there is one.
    @ViewBuilder
    func numericKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
