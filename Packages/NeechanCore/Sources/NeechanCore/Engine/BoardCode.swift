import Foundation

/// A board's short code, as a reader might type it.
///
/// One place, because three had grown: the search box, the settings screen and
/// now the screen the app opens on all have to agree on what `/B/ ` means, and
/// a stored code that the launch cannot open is a preference that silently does
/// nothing.
public enum BoardCode {
    /// 2ch board codes are short and alphanumeric.
    private static let maximumLength = 12

    /// Reads a code out of whatever was typed, or nothing if it cannot be one.
    ///
    /// Slashes go because readers write `/b/`, case goes because the site is
    /// lower case, and whitespace goes because a keyboard adds it. What is left
    /// has to be ASCII letters and digits with at least one letter: without
    /// that last rule a bare post number would read as a board.
    public static func normalized(_ input: String) -> String? {
        let code = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !code.isEmpty, code.count <= maximumLength else { return nil }
        guard code.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII }) else { return nil }
        guard code.contains(where: \.isLetter) else { return nil }
        return code
    }

    /// Whether this is a code the site could have.
    public static func isValid(_ code: String) -> Bool {
        normalized(code) == code
    }
}
