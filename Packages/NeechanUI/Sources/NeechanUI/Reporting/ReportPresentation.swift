import NeechanAPI
import NeechanCore
import SwiftUI

/// Presents the report screen this site asks for, and the confirmation after it.
///
/// One modifier doing both, and deliberately not generic: every screen that
/// offers reporting already carries a long modifier chain — the thread's is long
/// enough that the file splits its body into pieces to stay inside what the
/// type checker will solve — and a sheet plus an overlay plus a `@ViewBuilder`
/// closure was more than it would take. This adds one non-generic entry and
/// builds the sheet itself.
///
/// It also keeps the choice between the two report screens in one place rather
/// than copied into each caller.
struct ReportPresentation: ViewModifier {
    let board: String
    /// The thread the report is filed against, or nil when the reported post is
    /// the thread — which is what a catalog row is showing.
    let thread: Int?
    @Binding var target: ReportTarget?
    @Binding var hasReported: Bool

    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .sheet(item: $target) { target in
                sheet(for: target.postNum)
            }
            .reportSentToast(isPresented: $hasReported)
    }

    /// Two shapes behind one menu item: 2ch takes a report as an API call, so
    /// the app draws the form; 4chan answers only with a page of its own, so
    /// the page is what the reader gets.
    ///
    /// `.none` cannot arrive here, because the menu item is not offered then,
    /// but it still has to be answered — and nothing is the honest answer for a
    /// site that takes no reports.
    @ViewBuilder
    private func sheet(for postNum: Int) -> some View {
        switch services.capabilities.reporting {
        case .api:
            ReportFormView(board: board, thread: thread ?? postNum, postNum: postNum) {
                hasReported = true
            }
        case .web:
            #if canImport(WebKit) && os(iOS)
            if let url = SiteLinks.report(
                board: board, postNum: postNum, on: services.settings.siteSelection
            ) {
                ReportWebSheet(url: url) { hasReported = true }
            }
            #endif
        case .none:
            EmptyView()
        }
    }
}

extension View {
    /// Offers the report screen for whatever post `target` names.
    func reportPresentation(
        board: String,
        thread: Int?,
        target: Binding<ReportTarget?>,
        hasReported: Binding<Bool>
    ) -> some View {
        modifier(
            ReportPresentation(
                board: board, thread: thread, target: target, hasReported: hasReported
            )
        )
    }
}
