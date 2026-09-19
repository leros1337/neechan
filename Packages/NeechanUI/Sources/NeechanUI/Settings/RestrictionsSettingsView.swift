import NeechanCore
import NeechanSettings
import SwiftUI

/// What the app will and will not show, in one place.
struct RestrictionsSettingsView: View {
    @Environment(AppServices.self) private var services

    /// Raised by the 18+ toggle on the way *on* only. The preference is not
    /// written until the reader answers, so the switch springs back on cancel
    /// — the source of truth never moved, which is how the system's own
    /// screens behave.
    @State private var isConfirmingAge = false

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Toggle(isOn: $settings.nsfwMode) {
                    Text("NSFW mode", bundle: .module)
                }
                .accessibilityIdentifier("nsfw-mode-toggle")
            } footer: {
                Text(
                    "With this off, every thumbnail is blurred until you tap it.",
                    bundle: .module
                )
            }

            Section {
                Toggle(isOn: adultBinding) {
                    Text("Adult 18+", bundle: .module)
                }
                .accessibilityIdentifier("mature-toggle")
            } footer: {
                // The two builds mean different things by this switch, so they
                // cannot share a footer. The App Store wording is also how the
                // UI tests recognise which build they are running against.
                if settings.isAppStore {
                    Text(
                        "The board list carries anime, manga and comics. With this on you can also open any other board by typing its code.",
                        bundle: .module
                    )
                    .accessibilityIdentifier("adult-gate-note-appstore")
                } else {
                    Text(
                        "With this off, boards meant for adults cannot be opened, and threads on them disappear from Favorites, History and Saved threads until you turn it back on. Nothing is deleted.",
                        bundle: .module
                    )
                    .accessibilityIdentifier("adult-gate-note")
                }
            }
        }
        .navigationTitle(Text("Restrictions", bundle: .module))
        .inlineNavigationTitle()
        .alert(Text("Are you 18 or older?", bundle: .module), isPresented: $isConfirmingAge) {
            Button {
                services.setMatureAllowed(true)
            } label: {
                Text("I am 18 or older", bundle: .module)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", bundle: .module)
            }
        } message: {
            Text("These boards carry explicit sexual content.", bundle: .module)
        }
    }

    /// Turning the gate off is immediate — that is the safe direction, and
    /// asking the reader to confirm that they want *less* shown to them would
    /// be ceremony for its own sake. Turning it on asks first.
    ///
    /// Written through `AppServices` rather than straight to settings so the
    /// repositories' view of the policy moves in the same step.
    private var adultBinding: Binding<Bool> {
        Binding(
            get: { services.settings.allowsMatureBoards },
            set: { isOn in
                if isOn {
                    isConfirmingAge = true
                } else {
                    services.setMatureAllowed(false)
                }
            }
        )
    }
}
