import NeechanAPI
import NeechanCore
import SwiftUI

/// Signs in with a 2ch passcode.
///
/// A passcode skips the captcha and raises the file limits, so the screen shows
/// what the server granted rather than only reporting success.
struct PasscodeLoginView: View {
    @Environment(AppServices.self) private var services

    @State private var passcode = ""
    @State private var state: SignInState = .idle

    private enum SignInState: Equatable {
        case idle
        case working
        case signedIn(type: String, expires: Date?)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField(text: $passcode) {
                    Text("Passcode", bundle: .module)
                }
                .noAutocapitalization()
                .autocorrectionDisabled()
                .onSubmit { Task { await signIn() } }

                Button {
                    Task { await signIn() }
                } label: {
                    if state == .working {
                        ProgressView()
                    } else {
                        Text("Sign in", bundle: .module)
                    }
                }
                .disabled(passcode.isEmpty || state == .working)
            } footer: {
                Text(
                    "A passcode is bought on the site. It removes the captcha and raises the file limit.",
                    bundle: .module
                )
            }

            switch state {
            case .signedIn(let type, let expires):
                Section {
                    LabeledContent {
                        Text(type)
                    } label: {
                        Text("Passcode", bundle: .module)
                    }
                    if let expires {
                        LabeledContent {
                            Text(expires, style: .date)
                        } label: {
                            Text("Expires", bundle: .module)
                        }
                    }
                } header: {
                    Text("Signed in", bundle: .module)
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            case .idle, .working:
                EmptyView()
            }
        }
        .navigationTitle(Text("Passcode", bundle: .module))
        .inlineNavigationTitle()
    }

    private func signIn() async {
        state = .working
        do {
            let response = try await services.client.passcodeLogin(passcode: passcode)
            guard let granted = response.passcode else {
                state = .failed(String(localized: "The site did not accept that passcode.", bundle: .module, locale: AppLocale.current))
                return
            }
            passcode = ""
            state = .signedIn(
                type: granted.type,
                expires: granted.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        } catch {
            state = .failed(error.readableMessage)
        }
    }
}
