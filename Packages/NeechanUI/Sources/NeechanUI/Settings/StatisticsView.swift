import NeechanCore
import SwiftUI

/// What the reader has done with the app.
struct StatisticsView: View {
    @Environment(AppServices.self) private var services

    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(timeInApp)
                        .monospacedDigit()
                } label: {
                    Text("Time in the app", bundle: .module)
                }

                LabeledContent {
                    Text(services.settings.statistics.threadsOpened, format: .number)
                        .monospacedDigit()
                } label: {
                    Text("Threads opened", bundle: .module)
                }

                // Left out where posting is locked off: the count could only
                // ever read zero, and a statistic that cannot move is not one.
                //
                // Asked of `settings.allowsPosting` rather than of
                // `services.allowsPosting`, which folds in the selected site's
                // capability -- this figure covers every site the reader has
                // posted on, so it must not come and go with the switcher.
                if services.settings.allowsPosting {
                    LabeledContent {
                        Text(services.settings.statistics.postsSent, format: .number)
                            .monospacedDigit()
                    } label: {
                        Text("Posts sent", bundle: .module)
                    }
                    .accessibilityIdentifier("stat-posts-sent")
                }
            } footer: {
                Text("Counted on this device only, and never sent anywhere.", bundle: .module)
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    Text("Reset statistics", bundle: .module)
                }
            }
        }
        .navigationTitle(Text("Statistics", bundle: .module))
        .inlineNavigationTitle()
        .confirmationDialog(
            Text("Reset all statistics?", bundle: .module),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                services.settings.resetStatistics()
            } label: {
                Text("Reset", bundle: .module)
            }
        }
    }

    /// Hours and minutes, since a reader counts their time in those and not in
    /// the seconds the value is kept as.
    private var timeInApp: String {
        let seconds = Int(services.settings.statistics.secondsInApp)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "0"
    }
}
