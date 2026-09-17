import NeechanAPI
import NeechanCore
import SwiftUI

/// Preferences about the site: which mirror and which board.
struct ForumSettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var defaultBoard = ""
    /// Set when what was typed is not a board the site lists.
    @State private var isUnknownBoard = false

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
                .accessibilityIdentifier("default-board")
            } header: {
                Text("Default board", bundle: .module)
            } footer: {
                // Its own section, with a footer about itself. It used to share
                // one with the catalog switch below, under a heading about the
                // board and a footer about the catalog, so the screen never
                // said what the field was for.
                if isUnknownBoard {
                    Text("No board with that code.", bundle: .module)
                } else {
                    Text("The app opens on this board. Leave it empty to start on the board list.", bundle: .module)
                }
            }

            Section {
                Toggle(isOn: $settings.catalogByDefault) {
                    Text("Open boards as the catalog", bundle: .module)
                }
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
        // Checked when the screen opens as well as when the field is submitted,
        // so a code stored before the board went away is called out rather than
        // sitting there looking fine.
        .task(id: defaultBoard) { await checkBoardExists() }
        .onChange(of: services.settings.domain) {
            Task { await services.handleDomainChange() }
        }
    }

    /// Stores what was typed, in the shape the rest of the app reads.
    private func saveDefaultBoard() {
        let code = BoardCode.normalized(defaultBoard)
        services.settings.defaultBoard = code
        // What could not be a code is left on screen rather than swept away, so
        // the reader can see what they typed beside the line saying it is not a
        // board.
        if let code { defaultBoard = code }
    }

    /// Asks the board list whether such a board exists.
    ///
    /// Stored either way: a reader may be offline, and a board the directory
    /// does not list is still worth opening.
    private func checkBoardExists() async {
        guard let code = BoardCode.normalized(defaultBoard) else {
            isUnknownBoard = !defaultBoard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return
        }
        guard let board = try? await services.boards.board(id: code) else {
            // No answer at all, from a list that could not be fetched. Saying
            // "no such board" then would be a guess.
            isUnknownBoard = false
            return
        }
        isUnknownBoard = board == nil
    }
}
