import Foundation

/// The post a report sheet is open for.
///
/// Shared rather than declared twice: the action is offered from the thread and
/// from the catalog, and both drive the same sheet with `sheet(item:)`, which
/// needs something `Identifiable` to key it on.
struct ReportTarget: Identifiable {
    let postNum: Int
    var id: Int { postNum }
}
