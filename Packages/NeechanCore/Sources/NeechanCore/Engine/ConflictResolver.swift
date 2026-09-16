import Foundation
import NeechanSettings

/// Picks the name a download should actually be written under.
public enum ConflictResolver {
    /// - Returns: the name to write, or nil when the download should be skipped.
    public static func resolve(
        fileName: String,
        existing: Set<String>,
        action: DownloadConflictAction
    ) -> String? {
        guard existing.contains(fileName) else { return fileName }

        switch action {
        case .replace:
            return fileName
        case .skip:
            return nil
        case .ask, .keepBoth:
            // `ask` reaching here means the reader already chose to keep both.
            return nextFreeName(fileName, existing: existing)
        }
    }

    private static func nextFreeName(_ fileName: String, existing: Set<String>) -> String {
        let name = fileName as NSString
        let stem = name.deletingPathExtension
        let fileExtension = name.pathExtension

        var counter = 2
        while counter < 10_000 {
            let candidate = fileExtension.isEmpty
                ? "\(stem) \(counter)"
                : "\(stem) \(counter).\(fileExtension)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
        // Practically unreachable; a timestamp guarantees progress.
        return "\(stem) \(Int(Date.now.timeIntervalSince1970)).\(fileExtension)"
    }
}
