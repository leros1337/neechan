import NeechanSettings
import SwiftUI

/// What the reader agrees to before the App Store build shows them anything.
///
/// Shown once, with no way past but the button: an agreement the reader can
/// dismiss is not one they made. Afterwards it stays readable from About,
/// because terms nobody can re-read are terms nobody agreed to either.
///
/// Every claim here is about something the app actually does. It describes the
/// filtering tools that exist — hiding a post or a thread, autohide rules, and
/// hiding by poster name — and promises no reporting pipeline, because there
/// is none to promise.
struct AgreementView: View {
    /// Nil when the agreement is only being re-read, which is what leaves out
    /// the button.
    var onAgree: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    ForEach(AgreementSection.all) { section in
                        sectionView(section)
                    }
                    contact
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            // This is the whole window at first launch, with no navigation bar
            // above it to hold the top of the screen, so the title would sit
            // under the clock without being told not to.
            .safeAreaPadding(.top)

            if let onAgree {
                Divider()
                Button(action: onAgree) {
                    Text("I agree", bundle: .module)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .padding(16)
                .accessibilityIdentifier("agreement-accept")
            }
        }
        // No `accessibilityAddTraits(.isModal)` here: applied to a container it
        // makes the container one element and takes its children out of the
        // tree, so the sections and the button stop being reachable — by
        // VoiceOver as well as by the tests. Nothing else is on screen at this
        // point anyway, which is what modality would have been claiming.
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Neechan", bundle: .module)
                .font(.title.weight(.bold))
            Text("End User License Agreement", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(
                "Please read the following terms carefully before using this application.",
                bundle: .module
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionView(_ section: AgreementSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(section.title, bundle: .module)
                    .font(.headline)
            } icon: {
                Image(systemName: section.systemImage)
                    .foregroundStyle(.tint)
            }
            Text(section.body, bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The address is not localized and not a `LocalizedStringKey`: it is data,
    /// and a translator must not be able to reword the only way to reach us.
    private var contact: some View {
        Link(destination: URL(string: "mailto:\(Self.contactAddress)")!) {
            Label {
                Text(verbatim: Self.contactAddress)
            } icon: {
                Image(systemName: "envelope")
            }
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agreement-contact")
    }

    static let contactAddress = "neechan-dev@proton.me"
}

/// One numbered term, kept apart from the view so the same five can be drawn
/// by the first-launch screen and by the copy in About.
struct AgreementSection: Identifiable {
    let id: String
    let systemImage: String
    let title: LocalizedStringKey
    let body: LocalizedStringKey

    /// Deliberately without a "Reporting & Blocking" section: Neechan has no
    /// report button and no way to block a poster, and a term promising both
    /// would be a term the app does not keep.
    ///
    /// Main-actor because `LocalizedStringKey` is not `Sendable`; the only
    /// readers are view bodies, which are already there.
    @MainActor
    static let all: [AgreementSection] = [
        AgreementSection(
            id: "age",
            systemImage: "18.circle",
            title: "Age Restriction",
            body: "You must be at least 18 years of age to use this application. By agreeing, you confirm that you are 18 or older."
        ),
        AgreementSection(
            id: "ugc",
            systemImage: "person.text.rectangle",
            title: "User Generated Content",
            body: "This app reads publicly posted content from third-party imageboards. Neechan does not host, publish or moderate any of it, and has no control over what those sites carry."
        ),
        AgreementSection(
            id: "tools",
            systemImage: "line.3.horizontal.decrease.circle",
            title: "Filtering What You See",
            body: "You can hide any post or thread, and autohide rules keep chosen posters, words and patterns out of your feed. Hidden posts stay hidden until you reveal them, and nothing you hide is shown to you again."
        ),
        AgreementSection(
            id: "tolerance",
            systemImage: "hand.raised",
            title: "No Tolerance Policy",
            body: "There is no tolerance for illegal or abusive material. If you come across something that should not be online, write to us at the address below and report it to the site hosting it."
        ),
        AgreementSection(
            id: "dmca",
            systemImage: "doc.text",
            title: "Content Reporting (DMCA)",
            body: "If you believe content reached through this app infringes your copyright or other rights, write to us with the details. Neechan hosts nothing, so we will direct your report to the third-party service that does."
        ),
    ]
}

#Preview {
    AgreementView(onAgree: {})
}
