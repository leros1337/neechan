import Foundation
import Synchronization

/// Compiled patterns, kept so a rule is not recompiled for every post.
///
/// A thread refresh evaluates every rule against every post; compiling a
/// pattern each time would dominate the work.
final class RegexCache: Sendable {
    static let shared = RegexCache()

    private let storage = Mutex<[String: NSRegularExpression?]>([:])

    /// The compiled pattern, or nil when it does not compile.
    func expression(for pattern: String) -> NSRegularExpression? {
        storage.withLock { cache in
            if let cached = cache[pattern] { return cached }
            let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            cache[pattern] = compiled
            return compiled
        }
    }

    func removeAll() {
        storage.withLock { $0.removeAll() }
    }
}
