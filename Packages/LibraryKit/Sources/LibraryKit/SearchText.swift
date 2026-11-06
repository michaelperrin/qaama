import Foundation

/// How search compares text, in every source: without case, accents or character width, and by any part
/// of a word. Stored text and typed text both go through `fold`, so a database only has to look for a
/// substring, and "1234" finds `DSCF1234.RAF` (a full-text index would only match the start of words).
///
/// The rule is the same everywhere: every word typed must be found in the file name or in a keyword.
public nonisolated enum SearchText {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The words of a search, folded; empty when there is nothing to search for.
    public static func words(in text: String) -> [String] {
        fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Several values (keywords) as one folded text to search in. Words never hold a line break, so a
    /// match can't straddle two values.
    public static func foldedList(_ values: [String]) -> String {
        values.map(fold).joined(separator: "\n")
    }

    /// Whether every word of `text` is in one of `values`; true when `text` has no word.
    public static func matches(_ text: String, in values: [String]) -> Bool {
        let haystack = foldedList(values)
        return words(in: text).allSatisfy { haystack.contains($0) }
    }

    /// The SQL `LIKE` pattern finding `word` anywhere, literally; to use with `ESCAPE '\'`.
    static func likePattern(containing word: String) -> String {
        let literal = word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(literal)%"
    }
}
