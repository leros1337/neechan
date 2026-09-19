import NeechanCore
import SwiftUI

/// The root of the settings tree.
///
/// Grouped the way the Android client groups them, so a reader coming from it
/// finds each preference where they expect it, rather than in one long list.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        List {
            Section {
                row("General", systemImage: "gearshape") { GeneralSettingsView() }
                row("Forum", systemImage: "network") { ForumSettingsView() }
                row("Appearance", systemImage: "paintpalette") { InterfaceSettingsView() }
                row("Contents", systemImage: "text.book.closed") { ContentsSettingsView() }
                row("Media", systemImage: "photo.on.rectangle") { MediaSettingsView() }
                // By route, not by view: a board refused anywhere in the app
                // sends the reader here, and both ways in have to land on the
                // same screen.
                routeRow("Restrictions", systemImage: "hand.raised", route: .restrictions)
            }

            Section {
                row("Autohide", systemImage: "line.3.horizontal.decrease.circle") {
                    AutohideRulesView()
                }
                row("Hidden threads", systemImage: "eye.slash") { HiddenThreadsView() }
                row("Saved threads", systemImage: "arrow.down.circle") { SavedThreadsView() }
                row("Statistics", systemImage: "chart.bar") { StatisticsView() }
            }

            Section {
                row("About", systemImage: "info.circle") { AboutView() }
            }
        }
        .groupedListStyle()
        .navigationTitle(Text("Settings", bundle: .module))
    }

    private func routeRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        route: AppRoute
    ) -> some View {
        NavigationLink(value: route) {
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .accessibilityIdentifier("settings-\(systemImage)")
    }

    private func row(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: systemImage)
            }
        }
        // Named after the section rather than its text, so the tests can find a
        // row whatever language the app is drawing itself in.
        .accessibilityIdentifier("settings-\(systemImage)")
    }
}
