import SwiftUI

extension View {
    /// Says that a report reached the site, briefly, and takes itself away.
    ///
    /// A modifier rather than a view copied into each screen: the report action
    /// is offered from the thread and from the catalog, and a confirmation that
    /// reads differently in the two places would suggest they did different
    /// things.
    func reportSentToast(isPresented: Binding<Bool>) -> some View {
        overlay(alignment: .bottom) {
            if isPresented.wrappedValue {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                    Text("Report sent", bundle: .module)
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .capsule)
                .padding(.bottom, 56)
                .accessibilityIdentifier("report-sent")
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.snappy) { isPresented.wrappedValue = false }
                }
            }
        }
    }
}
