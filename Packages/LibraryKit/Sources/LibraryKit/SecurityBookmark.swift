import Foundation

/// Security-scoped bookmarks: the sandbox's way to keep access to a folder the user picked.
nonisolated enum SecurityBookmark {
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// The URL must be accessible when called (right after the picker, or inside a resolved scope).
    static func make(for url: URL) throws -> Data {
        try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark; `isStale` asks for the bookmark to be made again once access is started.
    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: resolutionOptions, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}
