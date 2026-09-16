import SwiftUI

/// The licences the app ships under and depends on.
///
/// FFmpeg is built GPL-3, and linking it makes this app GPL-3 as well, so the
/// notice is part of the app rather than a file in the repository.
struct LicensesView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let license: String
        let url: String
    }

    private let entries = [
        Entry(
            name: "Neechan",
            license: "GPL-3.0",
            url: "https://www.gnu.org/licenses/gpl-3.0.html"
        ),
        Entry(
            name: "KSPlayer",
            license: "GPL-3.0",
            url: "https://github.com/kingslay/KSPlayer"
        ),
        Entry(
            name: "FFmpegKit",
            license: "GPL-3.0",
            url: "https://github.com/kingslay/FFmpegKit"
        ),
    ]

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    if let url = URL(string: entry.url) {
                        Link(destination: url) {
                            LabeledContent {
                                Text(entry.license)
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(entry.name)
                            }
                        }
                    }
                }
            } footer: {
                Text(
                    "Neechan plays WebM through FFmpeg, which is distributed under the GPL. The app is therefore GPL-3.0 as well, and its source is available.",
                    bundle: .module
                )
            }
        }
        .groupedListStyle()
        .navigationTitle(Text("Licenses", bundle: .module))
        .inlineNavigationTitle()
    }
}
