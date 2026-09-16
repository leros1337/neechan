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
            }

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
                    "A backup holds your favorites, history and rules. Importing adds what is missing and leaves the rest alone.",
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
            let backup = try await services.backup.export(settings: [:])
            exportDocument = BackupDocument(backup: backup)
            isExporting = true
        } catch {
            message = AlertMessage(
                text: String(localized: "The backup could not be built.", bundle: .module, locale: AppLocale.current)
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
            let summary = try await services.backup.import(backup)
            message = AlertMessage(
                text: String(
                    localized: "Added \(summary.total) items.",
                    bundle: .module
                )
            )
        } catch {
            message = AlertMessage(
                text: String(localized: "That file is not a Neechan backup.", bundle: .module, locale: AppLocale.current)
            )
        }
    }
}

/// A one-line alert, as an identifiable value so `alert(item:)` can drive it.
struct AlertMessage: Identifiable {
    let id = UUID()
    let text: String
}
