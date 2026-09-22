import NeechanAPI
import NeechanCore
import SwiftUI

/// Preferences about the site: which mirror and which board.
struct ForumSettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var defaultBoard = ""
    /// Set when what was typed is not a board the site lists.
    @State private var isUnknownBoard = false
    @State private var isRestrictedBoard = false

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Picker(selection: siteBinding) {
                    ForEach(Imageboard.allCases) { site in
                        // Proper nouns; not translated.
                        Text(verbatim: site.displayName).tag(site)
                    }
                } label: {
                    Text("Imageboard", bundle: .module)
                }
                .accessibilityIdentifier("imageboard-setting")
            } footer: {
                Text(
                    "Favourites, history and everything else you keep belong to the imageboard they came from.",
                    bundle: .module
                )
            }

            // One of the two places a site is named rather than asked what it
            // can do: this picker is literally a list of 2ch's own mirrors.
            if services.site == .dvach {
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
                        "Every mirror serves the same content. Your passcode and age confirmation move with you.",
                        bundle: .module
                    )
                }
            }

            Section {
                TextField(text: $defaultBoard) {
                    Text("Board code, such as a", bundle: .module)
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
                if isRestrictedBoard {
                    Text("The board you typed is turned off in Restrictions.", bundle: .module)
                } else if isUnknownBoard {
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
                // A passcode buys a shorter path to posting — no captcha and
                // larger files — so a build that cannot post has nothing to
                // spend one on, and a screen pointing at a purchase made off
                // the store would be pointing at nothing. Asked of the posting
                // lock rather than of the build, so the reason stays in the
                // condition.
                if services.capabilities.passcode, services.allowsPosting {
                    NavigationLink {
                        PasscodeLoginView()
                    } label: {
                        Label {
                            Text("Passcode", bundle: .module)
                        } icon: {
                            Image(systemName: "key")
                        }
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
    }

    /// Through `select` rather than straight to settings, for the same reason
    /// the board list's switcher is: the client has to be re-pointed before the
    /// new value is observable to anything that reloads on it.
    private var siteBinding: Binding<Imageboard> {
        Binding(
            get: { services.settings.imageboard },
            set: { services.select($0) }
        )
    }

    /// Stores what was typed, in the shape the rest of the app reads.
    private func saveDefaultBoard() {
        let code = BoardCode.normalized(defaultBoard, for: services.site)
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
        guard let code = BoardCode.normalized(defaultBoard, for: services.site) else {
            isUnknownBoard = !defaultBoard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            isRestrictedBoard = false
            return
        }

        // Asked of the table rather than the directory, which works offline —
        // and which matters because a restricted board is absent from the
        // directory, so asking it would answer "no such board" instead.
        isRestrictedBoard = !services.contentPolicy.allowsOpening(code: code, on: services.site)
        guard !isRestrictedBoard else {
            isUnknownBoard = false
            return
        }

        // `do`/`catch` rather than `try?`: the latter flattens the optional the
        // lookup returns into the one it adds, so a board that is simply not
        // listed became indistinguishable from a fetch that failed, and this
        // line could never be true.
        do {
            isUnknownBoard = try await services.boards.board(id: code) == nil
        } catch {
            // No answer at all, from a list that could not be fetched. Saying
            // "no such board" then would be a guess.
            isUnknownBoard = false
        }
    }
}
