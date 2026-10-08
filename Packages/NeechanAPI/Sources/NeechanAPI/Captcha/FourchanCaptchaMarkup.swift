import Foundation

/// A fragment of HTML from 4chan's captcha, as words and pictures.
///
/// The site's own script puts a step's prompt, a wait's message and a refusal
/// on the page as `innerHTML`, and the site writes them accordingly: a prompt
/// is its instructions with the picture it asks about inline as a `data:`
/// image, and a wait can link to the page that lifts it. Shown as plain text,
/// both were unreadable.
///
/// Only what those carry is understood: line breaks, links that go to the web
/// and pictures that come inside the reply itself. Every other tag is dropped
/// and its words kept, and nothing is ever fetched to draw this.
public struct FourchanCaptchaMarkup: Sendable, Hashable {
    /// The words, with any link the site put on them.
    public let text: AttributedString
    /// Base64 PNGs, in the order they appear.
    public let images: [String]

    public init(html: String) {
        var text = AttributedString()
        var images: [String] = []
        var link: URL?
        var pending = ""

        func flush() {
            guard !pending.isEmpty else { return }
            var run = AttributedString(HTMLEntities.decode(pending))
            run.link = link
            text += run
            pending = ""
        }

        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "<", let close = html[index...].firstIndex(of: ">") else {
                pending.append(html[index])
                index = html.index(after: index)
                continue
            }
            let tag = String(html[html.index(after: index)..<close])
            index = html.index(after: close)
            flush()

            switch Self.name(of: tag) {
            case "br":
                text += AttributedString("\n")
            case "a":
                link = Self.attribute("href", in: tag).flatMap(Self.followable)
            case "/a":
                link = nil
            case "img":
                if let source = Self.attribute("src", in: tag), let base64 = Self.inlinePicture(source) {
                    images.append(base64)
                }
            default:
                break
            }
        }
        flush()

        self.text = Self.trimmed(text)
        self.images = images
    }

    public var isEmpty: Bool { text.characters.isEmpty && images.isEmpty }

    /// `a`, `/a`, `br`, `img`, lowercased; whatever else, ignored.
    private static func name(of tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        let closing = trimmed.hasPrefix("/")
        let name = trimmed.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
        return closing ? "/" + name : name
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?i)\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return HTMLEntities.decode(String(tag[range]))
            }
        }
        return nil
    }

    /// Only a link to the web: anything else stays words.
    private static func followable(_ href: String) -> URL? {
        guard let url = URL(string: href.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    /// `data:image/png;base64,…` → the base64. A picture that would have to
    /// be fetched from somewhere is left out.
    private static func inlinePicture(_ source: String) -> String? {
        guard source.lowercased().hasPrefix("data:image/"),
              let marker = source.range(of: ";base64,")
        else { return nil }
        let base64 = String(source[marker.upperBound...])
        return base64.isEmpty ? nil : base64
    }

    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var text = text
        while let first = text.characters.first, first.isWhitespace {
            text.removeSubrange(text.startIndex..<text.characters.index(after: text.startIndex))
        }
        while let last = text.characters.last, last.isWhitespace {
            text.removeSubrange(text.characters.index(before: text.endIndex)..<text.endIndex)
        }
        return text
    }
}
