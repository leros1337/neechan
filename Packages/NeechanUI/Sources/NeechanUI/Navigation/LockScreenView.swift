import SwiftUI

/// What stands in for the app while it is locked, or merely off screen.
///
/// Deliberately empty of content. Nothing is blurred and nothing is redacted:
/// either can lose the race with the snapshot the system takes for the app
/// switcher, and a blurred thread still says what the reader was reading.
struct LockScreenView: View {
    /// Whether the reader can do anything about it, or is only looking at the
    /// cover over an app that is off screen.
    let isLocked: Bool
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)

                if isLocked {
                    Button(action: onUnlock) {
                        Text("Unlock", bundle: .module)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("unlock")
                }
            }
        }
    }

    /// The colour the launch screen paints, so the cover and the launch look
    /// like the same screen rather than two.
    private static var background: Color {
        Color(
            light: Color(red: 0.961, green: 0.965, blue: 0.976),
            dark: Color(red: 0.066, green: 0.070, blue: 0.078)
        )
    }
}

extension Color {
    /// One colour for each appearance, without an asset catalogue: this is
    /// drawn by a package, and the catalogue belongs to the app.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self = light
        #endif
    }
}
