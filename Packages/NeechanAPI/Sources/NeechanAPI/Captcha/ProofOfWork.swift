import CryptoKit
import Foundation

/// Solves the site's proof-of-work challenge.
///
/// A linear search over at most a few tens of thousands of SHA-512 hashes,
/// which takes milliseconds. It runs off the main actor because it is still a
/// tight CPU loop and the reply form must stay responsive.
public enum ProofOfWork {
    /// Hard cap on the search, whatever the server asks for.
    ///
    /// The observed limit is 20 000. A server that sent a far larger one, by
    /// mistake or otherwise, would otherwise pin a core indefinitely.
    public static let searchCeiling = 200_000

    /// - Returns: the number to send as `2ch_challenge`, or nil when the
    ///   challenge cannot be solved within its limit.
    public static func solve(_ challenge: CaptchaChallenge) async -> Int? {
        guard challenge.template.contains("%d"), challenge.limit > 0 else { return nil }
        let bound = min(challenge.limit, searchCeiling)
        let expected = challenge.hash.lowercased()

        return await Task.detached(priority: .userInitiated) {
            let parts = challenge.template.components(separatedBy: "%d")
            let prefix = Array(parts[0].utf8)
            let suffix = Array(parts.dropFirst().joined(separator: "%d").utf8)

            var candidate = Data()
            candidate.reserveCapacity(prefix.count + suffix.count + 8)

            for number in 0..<bound {
                // Cancellation is checked in batches: reading the flag on every
                // iteration costs more than the hash does.
                if number % 512 == 0, Task.isCancelled { return nil }

                candidate.removeAll(keepingCapacity: true)
                candidate.append(contentsOf: prefix)
                candidate.append(contentsOf: Array(String(number).utf8))
                candidate.append(contentsOf: suffix)

                if SHA512.hash(data: candidate).hexString == expected {
                    return number
                }
            }
            return nil
        }.value
    }
}

extension Sequence<UInt8> {
    /// Lowercase hexadecimal, which is how the site writes its hashes.
    var hexString: String {
        var output = ""
        output.reserveCapacity(128)
        for byte in self {
            output.append(Self.hexDigits[Int(byte >> 4)])
            output.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return output
    }

    private static var hexDigits: [Character] {
        ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    }
}
