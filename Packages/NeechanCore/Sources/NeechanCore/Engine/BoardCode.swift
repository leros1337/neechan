import Foundation
import NeechanAPI

/// Normalises board codes typed by the reader.
///
/// Board codes are short and alphanumeric on both sites, so this is mostly
/// about stripping the slashes people write them with.
public enum BoardCode {
    private static let maximumLength = 12
    /// The longest an all-digit code may be. A post number is never this short,
    /// and the only numeric board either site has is a single digit.
    private static let maximumNumericLength = 2

    public static func normalized(_ input: String, for site: Imageboard = .dvach) -> String? {
        let code = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !code.isEmpty, code.count <= maximumLength else { return nil }
        guard code.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII }) else { return nil }
        // Without a letter a bare post number would read as a board code. 4chan
        // has one all-digit board, /3/, so a digit-only code is allowed there —
        // but only a very short one, which a post number never is.
        if !code.contains(where: \.isLetter) {
            guard site.allowsNumericBoardCodes, code.count <= maximumNumericLength else {
                return nil
            }
        }
        return code
    }

    public static func isValid(_ code: String, for site: Imageboard = .dvach) -> Bool {
        normalized(code, for: site) == code
    }
}
