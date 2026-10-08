import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Version, licences, and the backup file.
struct AboutView: View {
    @Environment(AppServices.self) private var services

    @State private var exportDocument: BackupDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var message: AlertMessage?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(Self.version)
                } label: {
                    Text("Version", bundle: .module)
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Text("Licenses", bundle: .module)
                }
                // Only where they were asked for: terms nobody agreed to are
                // not this app's terms, and a row explaining otherwise would
                // be a row that misleads.
                if services.settings.isRestricted {
                    NavigationLink {
                        AgreementView()
                            .navigationTitle(Text("Terms", bundle: .module))
                            .inlineNavigationTitle()
                    } label: {
                        Text("Terms", bundle: .module)
                    }
                    .accessibilityIdentifier("about-terms")
                }
            }

            Section {
                let links = AboutLinks(locale: AppLocale.current)
                Link(destination: links.website) {
                    Label {
                        Text("Website", bundle: .module)
                    } icon: {
                        Image(systemName: "globe")
                    }
                }
                Link(destination: links.privacyPolicy) {
                    Label {
                        Text("Privacy policy", bundle: .module)
                    } icon: {
                        Image(systemName: "hand.raised")
                    }
                }
                Link(destination: links.sourceCode) {
                    Label {
                        Text("Source code", bundle: .module)
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Link(destination: links.contact) {
                    Label {
                        Text("Contact", bundle: .module)
                    } icon: {
                        Image(systemName: "envelope")
                    }
                }
            }
            .accessibilityIdentifier("about-links")

            Section {
                Button {
                    Task { await prepareExport() }
                } label: {
                    Label {
                        Text("Export backup", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button {
                    isImporting = true
                } label: {
                    Label {
                        Text("Import backup", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            } header: {
                Text("Backup", bundle: .module)
            } footer: {
                Text(
                    "A backup holds your settings, statistics, favorites, history, hidden posts and themes. Importing takes its settings and adds whatever else is missing.",
                    bundle: .module
                )
            }
        }
        .navigationTitle(Text("About", bundle: .module))
        .inlineNavigationTitle()
        .backupFileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            onResult: { message = $0 }
        )
        .jsonFileImporter(isPresented: $isImporting) { url in
            Task { await runImport(from: url) }
        }
        .alert(item: $message) { message in
            Alert(title: Text(message.text))
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func prepareExport() async {
        do {
            let backup = try await services.makeBackup()
            exportDocument = BackupDocument(backup: backup)
            isExporting = true
        } catch {
            message = AlertMessage(
                text: String(localized: "The backup could not be built.", bundle: .module.forAppLanguage(), locale: AppLocale.current)
            )
        }
    }

    private func runImport(from url: URL) async {
        // A file picked from another app arrives as a security-scoped URL, which
        // has to be opened before it can be read.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let backup = try BackupCodec.decode(Data(contentsOf: url))
            let restored = try await services.restore(from: backup)
            // The setting says which icon; only the system can put it on the
            // home screen, and it does nothing when it is already there.
            if restored.restoredSettings {
                await AppIconSwitcher.apply(.named(services.settings.appIconName))
            }
            let summary = restored.imported
            message = AlertMessage(
                text: restored.restoredSettings
                    ? String(
                        localized: "Added \(summary.total) items and restored the settings.",
                        bundle: .module.forAppLanguage(),
                        locale: AppLocale.current
                    )
                    : String(
                        localized: "Added \(summary.total) items.",
                        bundle: .module.forAppLanguage(),
                        locale: AppLocale.current
                    )
            )
        } catch {
            message = AlertMessage(
                text: String(localized: "That file is not a Neechan backup.", bundle: .module.forAppLanguage(), locale: AppLocale.current)
            )
        }
    }
}

/// Where the rows in About lead.
///
/// The site's front page picks its language from the browser's, which is the
/// device's, and the reader may have set the app to another. So the app names
/// the language itself, and falls back to English where the site has no page.
struct AboutLinks {
    static let siteLanguages: Set<String> = ["en", "ru", "de"]

    let website: URL
    let privacyPolicy: URL
    let sourceCode = URL(string: "https://github.com/leros1337/neechan")!
    let contact = URL(string: "mailto:\(AgreementView.contactAddress)")!

    init(locale: Locale) {
        let code = locale.language.languageCode?.identifier ?? "en"
        let language = Self.siteLanguages.contains(code) ? code : "en"
        let site = URL(string: "https://neechan.pro/\(language)/")!
        website = site
        privacyPolicy = site.appending(path: "privacy")
    }
}

/// A one-line alert, as an identifiable value so `alert(item:)` can drive it.
struct AlertMessage: Identifiable {
    let id = UUID()
    let text: String
}
