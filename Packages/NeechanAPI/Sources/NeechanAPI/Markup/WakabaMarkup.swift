import Foundation

/// The markup the site accepts in a post body.
///
/// A mix of wakaba syntax and bulletin-board tags, which is what 2ch parses.
/// The reply form's toolbar inserts these around the reader's selection.
public enum WakabaMarkup {
    public enum Style: String, CaseIterable, Sendable, Identifiable {
        case bold
        case italic
        case underline
        case strikethrough
        case overline
        case spoiler
        case code
        case superscript
        case `subscript`

        public var id: String { rawValue }

        /// The characters placed before and after the selection.
        public var markers: (opening: String, closing: String) {
            switch self {
            case .bold: ("**", "**")
            case .italic: ("*", "*")
            case .underline: ("__", "__")
            case .strikethrough: ("[s]", "[/s]")
            case .overline: ("[o]", "[/o]")
            case .spoiler: ("%%", "%%")
            case .code: ("[code]", "[/code]")
            case .superscript: ("[sup]", "[/sup]")
            case .subscript: ("[sub]", "[/sub]")
            }
        }

        /// SF Symbol for the toolbar button.
        public var systemImage: String {
            switch self {
            case .bold: "bold"
            case .italic: "italic"
            case .underline: "underline"
            case .strikethrough: "strikethrough"
            case .overline: "textformat.abc.dottedunderline"
            case .spoiler: "eye.slash"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .superscript: "textformat.superscript"
            case .subscript: "textformat.subscript"
            }
        }
    }

    /// Wraps text in a style's markers.
    public static func wrap(_ text: String, in style: Style) -> String {
        let markers = style.markers
        return markers.opening + text + markers.closing
    }

    /// Wraps text and says where the cursor should end up.
    ///
    /// With nothing selected the markers are inserted empty and the cursor goes
    /// between them, so the reader can just carry on typing.
    public static func wrapping(
        _ selection: String,
        in style: Style
    ) -> (text: String, cursorOffset: Int) {
        let markers = style.markers
        let text = wrap(selection, in: style)
        let offset = selection.isEmpty
            ? markers.opening.count
            : text.count
        return (text, offset)
    }

    /// Prefixes every line with the greentext marker.
    public static func quote(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                // Lines the reader already quoted are left as they are, so
                // quoting a quote does not stack markers.
                line.hasPrefix(">") ? String(line) : ">" + line
            }
            .joined(separator: "\n") + "\n"
    }

    /// The reference that opens a reply to a post.
    public static func replyLink(to num: Int) -> String {
        ">>\(num)\n"
    }

    /// A reply that opens with the link and then quotes the text.
    public static func quotePost(num: Int, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return replyLink(to: num) }
        return replyLink(to: num) + quote(trimmed)
    }
}
