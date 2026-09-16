import Foundation

/// Splits a comment body into text and tag tokens.
///
/// Deliberately lenient: moderators can inject arbitrary HTML into a post, so
/// anything that does not look like a tag is text rather than an error.
struct CommentHTMLTokenizer {
    enum Token: Equatable {
        case text(String)
        case start(name: String, attributes: [String: String], selfClosing: Bool)
        case end(name: String)
    }

    func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        let scalars = Array(html)
        var index = 0

        func flushText() {
            if !text.isEmpty {
                tokens.append(.text(text))
                text = ""
            }
        }

        while index < scalars.count {
            guard scalars[index] == "<" else {
                text.append(scalars[index])
                index += 1
                continue
            }

            // A `<` only opens a tag when a name, a closer or a declaration
            // follows it. This is the browser rule, and it keeps arithmetic such
            // as "2 < 3 and 5 > 4" as text instead of eating it as markup.
            let next = index + 1 < scalars.count ? scalars[index + 1] : " "
            guard next.isLetter || next == "/" || next == "!" || next == "?" else {
                text.append("<")
                index += 1
                continue
            }

            // A comment: skip to its terminator, or to the end if unterminated.
            if scalars[index...].starts(with: "<!--") {
                flushText()
                index = indexAfter("-->", from: index + 4, in: scalars) ?? scalars.count
                continue
            }

            // A doctype or processing instruction: drop it.
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                flushText()
                index = indexAfter(">", from: index + 1, in: scalars) ?? scalars.count
                continue
            }

            guard let close = firstIndex(of: ">", from: index + 1, in: scalars) else {
                // No terminator: the rest of the input is literal text.
                text.append(contentsOf: scalars[index...])
                index = scalars.count
                continue
            }

            let inside = String(scalars[(index + 1)..<close])
            if inside.isEmpty {
                // `<>` is not a tag.
                text.append("<>")
                index = close + 1
                continue
            }

            flushText()
            tokens.append(parseTag(inside))
            index = close + 1
        }

        flushText()
        return tokens
    }

    // MARK: Pieces

    private func parseTag(_ inside: String) -> Token {
        var body = inside
        if body.hasPrefix("/") {
            let name = body.dropFirst()
                .prefix { !$0.isWhitespace && $0 != "/" }
                .lowercased()
            return .end(name: name)
        }

        let selfClosing = body.hasSuffix("/")
        if selfClosing { body.removeLast() }

        let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        let rest = body.dropFirst(name.count)
        return .start(
            name: name,
            attributes: parseAttributes(String(rest)),
            selfClosing: selfClosing
        )
    }

    private func parseAttributes(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }

            let nameStart = index
            while index < characters.count,
                  !characters[index].isWhitespace,
                  characters[index] != "=" {
                index += 1
            }
            let name = String(characters[nameStart..<index]).lowercased()
            guard !name.isEmpty else { index += 1; continue }

            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] == "=" else {
                // A valueless attribute, such as `disabled`.
                attributes[name] = ""
                continue
            }
            index += 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else {
                attributes[name] = ""
                break
            }

            let value: String
            let quote = characters[index]
            if quote == "\"" || quote == "'" {
                index += 1
                let start = index
                while index < characters.count, characters[index] != quote { index += 1 }
                value = String(characters[start..<index])
                if index < characters.count { index += 1 }
            } else {
                let start = index
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
                value = String(characters[start..<index])
            }
            // Attribute values carry entities too: 2ch writes `&#47;` for `/`.
            attributes[name] = HTMLEntities.decode(value)
        }
        return attributes
    }

    private func firstIndex(of character: Character, from start: Int, in scalars: [Character]) -> Int? {
        var index = start
        while index < scalars.count {
            if scalars[index] == character { return index }
            index += 1
        }
        return nil
    }

    private func indexAfter(_ needle: String, from start: Int, in scalars: [Character]) -> Int? {
        let needleCharacters = Array(needle)
        var index = start
        while index + needleCharacters.count <= scalars.count {
            if Array(scalars[index..<(index + needleCharacters.count)]) == needleCharacters {
                return index + needleCharacters.count
            }
            index += 1
        }
        return nil
    }
}
