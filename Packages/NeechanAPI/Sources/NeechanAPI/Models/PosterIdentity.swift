import Foundation

/// A colour the server names in an inline style.
public struct PostColor: Sendable, Hashable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Reads `rgb(24,212,14)` and `#18d40e`, which are the two spellings the
    /// site uses for a poster's colour.
    public init?(cssLike text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.lowercased().hasPrefix("rgb") {
            let numbers = trimmed
                .drop { $0 != "(" }
                .dropFirst()
                .prefix { $0 != ")" }
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 3 else { return nil }
            self.init(red: numbers[0], green: numbers[1], blue: numbers[2])
            return
        }

        var hex = trimmed
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Int((value >> 16) & 0xFF),
            green: Int((value >> 8) & 0xFF),
            blue: Int(value & 0xFF)
        )
    }
}

/// The badge beside a poster's name: a country flag on most boards, a
/// board-specific image on a few.
public struct PostIcon: Sendable, Hashable {
    /// Server-relative path to the image the site would draw.
    public let imagePath: String?
    /// What the site calls it, when it says.
    public let title: String?
    /// The country's flag as an emoji, when the icon is a country flag.
    ///
    /// Preferred over the image: it needs no request, scales with the text and
    /// is already in the reader's font.
    public let flagEmoji: String?

    public init(imagePath: String?, title: String?, flagEmoji: String?) {
        self.imagePath = imagePath
        self.title = title
        self.flagEmoji = flagEmoji
    }

    /// Reads the `<img>` tag the site sends.
    ///
    /// - Returns: nil when there is no icon at all.
    public init?(html: String) {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path = HTMLTagScanner.attribute("src", in: trimmed)
        let title = HTMLTagScanner.attribute("title", in: trimmed)
            ?? HTMLTagScanner.attribute("alt", in: trimmed)
        let flag = path.flatMap(PostIcon.flagEmoji(forImagePath:))

        guard path != nil || title != nil else { return nil }
        self.init(
            imagePath: path,
            title: title.map(HTMLEntities.decode),
            flagEmoji: flag
        )
    }

    /// Turns `/flags/RU.png` into 🇷🇺.
    ///
    /// Flags live under `/flags/` and are named by their two-letter country
    /// code, which maps directly onto the regional indicator characters.
    static func flagEmoji(forImagePath path: String) -> String? {
        guard
            path.lowercased().contains("/flags/"),
            let file = path.split(separator: "/").last
        else {
            return nil
        }
        let code = file.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
        guard code.count == 2, code.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }

        var emoji = ""
        for character in code.unicodeScalars {
            guard let scalar = Unicode.Scalar(127_397 + character.value) else { return nil }
            emoji.unicodeScalars.append(scalar)
        }
        return emoji
    }
}

/// Pulls values out of the small HTML fragments the site puts in plain-text
/// fields.
///
/// Deliberately not the comment parser: these are one tag with a handful of
/// attributes, and building a node tree for them would be more machinery than
/// the job needs.
enum HTMLTagScanner {
    /// The value of `name="..."` or `name='...'`, whichever comes first.
    static func attribute(_ name: String, in html: String) -> String? {
        for quote in ["\"", "'"] {
            let opening = "\(name)=\(quote)"
            guard let start = html.range(of: opening, options: .caseInsensitive) else { continue }
            guard let end = html[start.upperBound...].firstIndex(of: Character(quote)) else { continue }
            let value = String(html[start.upperBound..<end])
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The text with every tag removed, entities decoded, and runs of space
    /// collapsed.
    static func plainText(_ html: String) -> String {
        var result = ""
        var isInsideTag = false
        for character in html {
            switch character {
            case "<": isInsideTag = true
            case ">": isInsideTag = false
            default: if !isInsideTag { result.append(character) }
            }
        }
        return HTMLEntities.decode(result)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The contents of the first element of this tag name, with the tag's own
    /// attributes alongside.
    static func firstElement(_ tag: String, in html: String) -> (attributes: String, text: String)? {
        guard let open = html.range(of: "<\(tag)", options: .caseInsensitive) else { return nil }
        guard let openEnd = html[open.upperBound...].firstIndex(of: ">") else { return nil }
        let attributes = String(html[open.upperBound..<openEnd])

        let contentStart = html.index(after: openEnd)
        guard
            let close = html.range(of: "</\(tag)", options: .caseInsensitive, range: contentStart..<html.endIndex)
        else {
            return nil
        }
        return (attributes, String(html[contentStart..<close.lowerBound]))
    }
}

/// A poster's name, as the site sends it.
///
/// Most boards send "Аноним". Boards with poster IDs send the word followed by
/// a generated nickname in a coloured span, which is the only thing telling one
/// poster from another in a thread.
public struct PosterName: Sendable, Hashable {
    public let displayName: String
    public let posterID: String?
    public let posterIDColor: PostColor?

    /// Parses the field, which may be plain text or may carry a span.
    public init(html: String) {
        let element = HTMLTagScanner.firstElement("span", in: html)

        if let element {
            posterID = HTMLTagScanner.plainText(element.text).nonEmpty
            posterIDColor = HTMLTagScanner.attribute("style", in: element.attributes)
                .flatMap(PosterName.colour(inStyle:))
        } else {
            posterID = nil
            posterIDColor = nil
        }

        // Everything outside the span, with the "ID:" label the site puts in
        // front of the nickname taken off.
        let beforeSpan = html.range(of: "<span", options: .caseInsensitive)
            .map { String(html[html.startIndex..<$0.lowerBound]) } ?? html
        var name = HTMLTagScanner.plainText(beforeSpan)
        if let label = name.range(of: "ID:", options: [.caseInsensitive, .backwards]) {
            name = String(name[name.startIndex..<label.lowerBound])
        }
        displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func colour(inStyle style: String) -> PostColor? {
        guard let range = style.range(of: "color:", options: .caseInsensitive) else { return nil }
        let value = style[range.upperBound...].prefix { $0 != ";" }
        return PostColor(cssLike: String(value))
    }
}

extension String {
    /// nil when there is nothing but whitespace here.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
