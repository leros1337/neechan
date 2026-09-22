import SwiftUI

/// The licences the app ships under and depends on.
///
/// FFmpeg is linked statically and is LGPL, which asks that the notice travel
/// with the app rather than sit only in the repository.
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
            license: "MIT",
            url: "https://opensource.org/license/mit"
        ),
        Entry(
            name: "FFmpeg",
            license: "LGPL-2.1-or-later",
            url: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html"
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
                    "Neechan plays video through FFmpeg, built without any GPL component and used under the LGPL. The build script and the app's own source are available, so this app can be rebuilt against a modified FFmpeg.",
                    bundle: .module
                )
            }
        }
        .groupedListStyle()
        .navigationTitle(Text("Licenses", bundle: .module))
        .inlineNavigationTitle()
    }
}
