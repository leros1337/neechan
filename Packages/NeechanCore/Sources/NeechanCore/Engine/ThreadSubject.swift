import Foundation

/// Whether a thread's subject is worth showing above its text.
///
/// 2ch fills `subject` with the beginning of the opening post when the poster
/// left it empty, so a card drew the same words twice: once in bold as a title
/// and again underneath as the preview.
public enum ThreadSubject {
    /// True when the subject is only the start of the comment repeated.
    ///
    /// Compared on normalised text because the site flattens the post's line
    /// breaks into the subject and cuts it mid-sentence, so the two are never
    /// equal — one is a prefix of the other.
    public static func echoes(_ subject: String, comment: String) -> Bool {
        let subject = normalised(subject)
        let comment = normalised(comment)
        guard !subject.isEmpty, !comment.isEmpty else { return false }
        return comment.hasPrefix(subject)
    }

    /// Lower-cased, with runs of whitespace collapsed and the ellipsis the site
    /// truncates with taken off the end.
    private static func normalised(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return String(collapsed.reversed().drop { $0 == "." || $0 == "\u{2026}" }.reversed())
            .trimmingCharacters(in: .whitespaces)
    }
}
