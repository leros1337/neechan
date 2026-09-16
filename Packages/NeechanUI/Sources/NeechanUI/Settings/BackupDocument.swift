import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UniformTypeIdentifiers)
/// The backup file, for the system's own save and open panels.
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(backup: NeechanBackup) {
        data = (try? BackupCodec.encode(backup)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension View {
    /// The save panel, with a name that carries the date so backups do not
    /// overwrite each other.
    @ViewBuilder
    func backupFileExporter(
        isPresented: Binding<Bool>,
        document: BackupDocument?,
        onResult: @escaping (AlertMessage) -> Void
    ) -> some View {
        fileExporter(
            isPresented: isPresented,
            document: document,
            contentType: .json,
            defaultFilename: "neechan-\(Date.now.formatted(.iso8601.year().month().day()))"
        ) { result in
            if case .failure = result {
                onResult(
                    AlertMessage(
                        text: String(localized: "The backup was not saved.", bundle: .module, locale: AppLocale.current)
                    )
                )
            }
        }
    }

    /// The open panel, restricted to JSON.
    @ViewBuilder
    func jsonFileImporter(
        isPresented: Binding<Bool>,
        onPicked: @escaping (URL) -> Void
    ) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { onPicked(url) }
        }
    }
}
#else
struct BackupDocument {
    init(backup: NeechanBackup) {}
}

extension View {
    func backupFileExporter(
        isPresented: Binding<Bool>,
        document: BackupDocument?,
        onResult: @escaping (AlertMessage) -> Void
    ) -> some View { self }

    func jsonFileImporter(
        isPresented: Binding<Bool>,
        onPicked: @escaping (URL) -> Void
    ) -> some View { self }
}
#endif

extension View {
    /// The system folder picker, for choosing where downloads are written.
    @ViewBuilder
    func downloadFolderPicker(
        isPresented: Binding<Bool>,
        onPicked: @escaping (URL) -> Void
    ) -> some View {
        #if canImport(UniformTypeIdentifiers)
        fileImporter(isPresented: isPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { onPicked(url) }
        }
        #else
        self
        #endif
    }
}
