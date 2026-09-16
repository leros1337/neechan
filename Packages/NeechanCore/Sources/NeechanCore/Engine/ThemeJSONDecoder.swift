import Foundation

/// A colour as plain numbers, so a theme can be stored and compared without
/// pulling SwiftUI into the engine.
public struct ThemeColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// Reads the spellings Android themes use: `#RGB`, `#RRGGBB`, `#AARRGGBB`,
    /// each with the `#` optional. Alpha comes first, as it does on Android.
    public init?(cssLike text: String) {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }

        switch digits.count {
        case 3:
            digits = digits.flatMap { [$0, $0] }.map(String.init).joined()
        case 6, 8:
            break
        default:
            return nil
        }
        guard let value = UInt32(digits, radix: 16) else { return nil }

        let hasAlpha = digits.count == 8
        let alpha = hasAlpha ? Double((value >> 24) & 0xFF) / 255 : 1
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Perceived brightness, used to tell a dark theme from a light one.
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

/// A colour scheme the reader can pick.
///
/// Liquid Glass supplies the chrome, so a theme here colours the content layer:
/// the accent, the page and card backgrounds, and the kinds of text a post has.
public struct NeechanTheme: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var accent: ThemeColor
    public var background: ThemeColor
    public var card: ThemeColor
    public var postText: ThemeColor
    public var secondaryText: ThemeColor
    public var link: ThemeColor
    public var quote: ThemeColor
    public var spoiler: ThemeColor
    public var isDark: Bool

    public init(
        id: String,
        name: String,
        accent: ThemeColor,
        background: ThemeColor,
        card: ThemeColor,
        postText: ThemeColor,
        secondaryText: ThemeColor,
        link: ThemeColor,
        quote: ThemeColor,
        spoiler: ThemeColor,
        isDark: Bool
    ) {
        self.id = id
        self.name = name
        self.accent = accent
        self.background = background
        self.card = card
        self.postText = postText
        self.secondaryText = secondaryText
        self.link = link
        self.quote = quote
        self.spoiler = spoiler
        self.isDark = isDark
    }

    /// The look the app ships with, and the one every unknown theme id falls
    /// back to.
    ///
    /// This is the palette that used to ship as "Midnight": a cool light-blue
    /// accent and the post colours that suit a dark board, which is how the app
    /// is mostly read. Light and dark mode are still the reader's Appearance
    /// setting — a theme here is only the accent and the colours inside a post,
    /// since Liquid Glass supplies the chrome.
    public static let builtIn = NeechanTheme(
        id: "neechan.system",
        name: "System",
        accent: ThemeColor(red: 0.30, green: 0.68, blue: 0.95),
        background: ThemeColor(red: 0.07, green: 0.09, blue: 0.11),
        card: ThemeColor(red: 0.11, green: 0.14, blue: 0.17),
        postText: ThemeColor(red: 0.90, green: 0.93, blue: 0.95),
        secondaryText: ThemeColor(red: 0.55, green: 0.60, blue: 0.65),
        link: ThemeColor(red: 0.30, green: 0.68, blue: 0.95),
        quote: ThemeColor(red: 0.50, green: 0.76, blue: 0.50),
        spoiler: ThemeColor(red: 0.18, green: 0.22, blue: 0.26),
        isDark: true
    )

    /// Whether this is one of the shipped looks, which cannot be deleted.
    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    /// The schemes the app ships with.
    ///
    /// Liquid Glass supplies the chrome, so a scheme here is mostly an accent
    /// and the few colours a post uses: the reader picks the character of the
    /// app without the app fighting the system's own materials.
    public static let builtIns: [NeechanTheme] = [
        builtIn,
        scheme(
            id: "neechan.graphite",
            name: "Graphite",
            accent: ThemeColor(red: 0.42, green: 0.45, blue: 0.50),
            quote: ThemeColor(red: 0.35, green: 0.55, blue: 0.40)
        ),
        scheme(
            id: "neechan.crimson",
            name: "Crimson",
            accent: ThemeColor(red: 0.83, green: 0.22, blue: 0.28),
            quote: ThemeColor(red: 0.45, green: 0.56, blue: 0.27)
        ),
        scheme(
            id: "neechan.forest",
            name: "Forest",
            accent: ThemeColor(red: 0.18, green: 0.56, blue: 0.35),
            quote: ThemeColor(red: 0.36, green: 0.49, blue: 0.24)
        ),
        scheme(
            id: "neechan.amethyst",
            name: "Amethyst",
            accent: ThemeColor(red: 0.55, green: 0.35, blue: 0.82),
            quote: ThemeColor(red: 0.40, green: 0.54, blue: 0.33)
        ),
        scheme(
            id: "neechan.amber",
            name: "Amber",
            accent: ThemeColor(red: 0.85, green: 0.58, blue: 0.13),
            quote: ThemeColor(red: 0.38, green: 0.53, blue: 0.28)
        ),
    ]

    /// A built-in with this id, if there is one.
    public static func builtIn(id: String) -> NeechanTheme? {
        builtIns.first { $0.id == id }
    }

    /// A light scheme that differs from the shipped one only where it has to.
    ///
    /// The backgrounds stay the system's, so the app keeps following light and
    /// dark mode; only the colours a reader actually notices are changed.
    private static func scheme(
        id: String,
        name: String,
        accent: ThemeColor,
        quote: ThemeColor
    ) -> NeechanTheme {
        NeechanTheme(
            id: id,
            name: name,
            accent: accent,
            background: builtIn.background,
            card: builtIn.card,
            postText: builtIn.postText,
            secondaryText: builtIn.secondaryText,
            link: accent,
            quote: quote,
            spoiler: builtIn.spoiler,
            isDark: false
        )
    }
}

/// Reads a Dashchan theme file.
///
/// Dashchan themes are a flat JSON object of colour names. Keys the app has no
/// use for are ignored, and keys it wants but does not find keep the built-in
/// colour, so a sparse file still produces a readable theme.
public enum ThemeJSONDecoder {
    public enum DecodingFailure: Error, Equatable, CustomStringConvertible {
        case notJSON
        case missingName

        public var description: String {
            switch self {
            case .notJSON: "The file is not a theme."
            case .missingName: "The theme has no name."
            }
        }
    }

    public static func decode(_ data: Data) throws(DecodingFailure) -> NeechanTheme {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let fields = object as? [String: Any]
        else {
            throw .notJSON
        }
        guard
            let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            name.isEmpty == false
        else {
            throw .missingName
        }

        func colour(_ keys: String..., default fallback: ThemeColor) -> ThemeColor {
            for key in keys {
                if let text = fields[key] as? String, let parsed = ThemeColor(cssLike: text) {
                    return parsed
                }
                // Android tooling sometimes writes the packed integer instead.
                if let number = fields[key] as? Int,
                   let parsed = ThemeColor(cssLike: String(format: "%08x", UInt32(truncatingIfNeeded: number))) {
                    return parsed
                }
            }
            return fallback
        }

        let base = NeechanTheme.builtIn
        let background = colour("window", "background", default: base.background)

        return NeechanTheme(
            id: identifier(for: name),
            name: name,
            accent: colour("accent", "primary", default: base.accent),
            background: background,
            card: colour("card", "post", default: base.card),
            postText: colour("post", "text", default: base.postText),
            secondaryText: colour("meta", "subtitle", default: base.secondaryText),
            link: colour("link", "accent", default: base.link),
            quote: colour("quote", default: base.quote),
            spoiler: colour("spoiler", default: base.spoiler),
            isDark: background.luminance < 0.5
        )
    }

    /// A stable id from the name, so importing the same file twice replaces the
    /// theme rather than stacking copies of it.
    static func identifier(for name: String) -> String {
        "imported." + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
