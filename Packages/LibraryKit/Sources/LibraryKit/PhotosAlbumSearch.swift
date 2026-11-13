import Foundation

/// Finds albums by name in the whole hierarchy, whatever folder they are in: with hundreds of
/// albums in nested folders, typing part of a name is faster than walking the menus.
///
/// Text is compared as in every other search (`SearchText`): without case or accents, by any part
/// of a word. Every word typed must be found in the album's title or in the name of a folder it is
/// in, so "2024 japon" finds the album "Japon" of the folder "2024".
///
/// Built once for a hierarchy, then asked on every key typed: folding and sorting are done up front.
public nonisolated struct PhotosAlbumSearch: Sendable {
    /// An album found, with where it is.
    public struct Match: Hashable, Sendable, Identifiable {
        public let album: PhotosAlbum
        /// The folders the album is in, outermost first; empty at the top level.
        public let folders: [String]

        public var id: PhotosAlbum.ID {
            album.id
        }
    }

    /// How well an album answers what was typed; the best come first.
    private enum Rank: Int, CaseIterable {
        /// The title starts with what was typed.
        case titlePrefix
        /// Every word typed starts a word of the title.
        case wordStarts
        /// Every word typed is somewhere in the title.
        case title
        /// A word was only found in the name of a folder.
        case folders
    }

    private struct Entry: Sendable {
        let match: Match
        /// The title, folded.
        let title: String
        /// The folders and the title, folded, one per line: a word can't straddle two of them.
        let path: String
    }

    /// By title, then by folders: the order of the results within a rank.
    private let entries: [Entry]

    /// `excludedID` leaves one album out: the one on screen, which adding to makes no sense.
    public init(tree: [PhotosAlbumNode], excluding excludedID: PhotosAlbum.ID? = nil) {
        var matches: [Match] = []
        func collect(_ nodes: [PhotosAlbumNode], in folders: [String]) {
            for node in nodes {
                switch node {
                case let .album(album):
                    if album.id != excludedID {
                        matches.append(Match(album: album, folders: folders))
                    }
                case let .folder(_, title, children):
                    collect(children, in: folders + [title])
                }
            }
        }
        collect(tree, in: [])
        matches.sort { lhs, rhs in
            let byTitle = lhs.album.title.localizedStandardCompare(rhs.album.title)
            if byTitle != .orderedSame {
                return byTitle == .orderedAscending
            }
            return lhs.folders.joined(separator: "\n").localizedStandardCompare(rhs.folders.joined(separator: "\n")) == .orderedAscending
        }
        entries = matches.map { match in
            Entry(match: match, title: SearchText.fold(match.album.title), path: SearchText.foldedList(match.folders + [match.album.title]))
        }
    }

    /// How many albums can be found.
    public var count: Int {
        entries.count
    }

    /// The albums answering `query`, best first; all of them, by title, when nothing is typed.
    public func matches(for query: String) -> [Match] {
        let words = SearchText.words(in: query)
        guard !words.isEmpty else { return entries.map(\.match) }
        let phrase = words.joined(separator: " ")
        var ranked = [[Match]](repeating: [], count: Rank.allCases.count)
        for entry in entries {
            if let rank = Self.rank(of: entry, words: words, phrase: phrase) {
                ranked[rank.rawValue].append(entry.match)
            }
        }
        return ranked.flatMap(\.self)
    }

    private static func rank(of entry: Entry, words: [String], phrase: String) -> Rank? {
        guard words.allSatisfy({ entry.path.contains($0) }) else { return nil }
        if entry.title.hasPrefix(phrase) {
            return .titlePrefix
        }
        guard words.allSatisfy({ entry.title.contains($0) }) else { return .folders }
        return words.allSatisfy { startsWord($0, in: entry.title) } ? .wordStarts : .title
    }

    /// Whether `word` is found in `text` where a word begins: at the start, or after anything that
    /// is neither a letter nor a digit.
    private static func startsWord(_ word: String, in text: String) -> Bool {
        var searched = text.startIndex ..< text.endIndex
        while let found = text.range(of: word, range: searched) {
            if found.lowerBound == text.startIndex {
                return true
            }
            let before = text[text.index(before: found.lowerBound)]
            if !before.isLetter, !before.isNumber {
                return true
            }
            searched = text.index(after: found.lowerBound) ..< text.endIndex
        }
        return false
    }
}
