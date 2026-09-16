import Foundation

/// Decodes the HTML character references 2ch emits.
///
/// Written by hand rather than delegated to `NSAttributedString`, which parses
/// entities only by spinning up WebKit on the main thread. Post bodies are
/// decoded off the main actor, in bulk, while scrolling.
public enum HTMLEntities {
    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "shy": "\u{00AD}",
        "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "mdash": "—", "ndash": "–",
        "hellip": "…", "middot": "·", "bull": "•", "deg": "°",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§",
        "para": "¶", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        // Accented Latin letters, which turn up in names and tripcodes copied
        // from elsewhere.
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü",
        "atilde": "ã", "ntilde": "ñ", "otilde": "õ", "ccedil": "ç",
        "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "Ntilde": "Ñ", "Ccedil": "Ç",
        "szlig": "ß", "aring": "å", "oslash": "ø", "aelig": "æ",
    ]

    /// Replaces every character reference in `text`. Anything that does not
    /// resolve is left exactly as it was, so a bare `&` survives.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while let ampersand = text[index...].firstIndex(of: "&") {
            result.append(contentsOf: text[index..<ampersand])
            index = ampersand

            // A reference is at most a handful of characters; cap the search so
            // a lone ampersand does not scan the rest of the comment.
            let limit = text.index(ampersand, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text[ampersand..<limit].firstIndex(of: ";") else {
                result.append("&")
                index = text.index(after: ampersand)
                continue
            }

            let body = text[text.index(after: ampersand)..<semicolon]
            if let character = character(forReference: body) {
                result.append(character)
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = text.index(after: ampersand)
            }
        }

        result.append(contentsOf: text[index...])
        return result
    }

    private static func character(forReference body: Substring) -> Character? {
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                scalarValue = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(digits, radix: 10)
            }
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return Character(scalar)
        }

        return named[String(body)]
    }
}
