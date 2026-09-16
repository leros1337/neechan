import Foundation

/// How alike two post bodies are.
///
/// Backs "hide similar posts", which readers use against copypasta that is
/// reposted with small edits. Word overlap catches that; an exact match would
/// not, and edit distance would be far too slow across a long thread.
public enum TextSimilarity {
    /// Above this, two posts count as the same thing said twice.
    ///
    /// Chosen so a padded repost still matches while two posts merely on the
    /// same topic do not.
    public static let defaultThreshold = 0.6

    /// Jaccard overlap of the two texts' word sets, from 0 to 1.
    public static func score(_ first: String, _ second: String) -> Double {
        let left = words(in: first)
        let right = words(in: second)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let shared = left.intersection(right).count
        let total = left.union(right).count
        guard total > 0 else { return 0 }
        return Double(shared) / Double(total)
    }

    public static func isSimilar(
        _ first: String,
        _ second: String,
        threshold: Double = defaultThreshold
    ) -> Bool {
        score(first, second) >= threshold
    }

    /// Lowercased words, with punctuation dropped.
    private static func words(in text: String) -> Set<String> {
        var result: Set<String> = []
        for run in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            // One and two letter words are noise: conjunctions and particles
            // appear in everything and would inflate every comparison.
            if run.count > 2 {
                result.insert(String(run))
            }
        }
        return result
    }
}
