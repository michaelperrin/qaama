import Foundation
import OSLog

/// Remembers the folders the user added, as security-scoped bookmarks, so the sandboxed app can reopen them.
struct FolderBookmarkStore {
    private let defaults: UserDefaults
    private let key = "libraryFolderBookmarks"
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FolderBookmarkStore")

    #if os(macOS)
    private let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private let creationOptions: URL.BookmarkCreationOptions = []
    private let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Folders saved earlier, in the order they were added. Unresolvable bookmarks are dropped.
    func restoreFolders() -> [URL] {
        var urls: [URL] = []
        var kept: [Data] = []
        for data in storedBookmarks {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions, bookmarkDataIsStale: &isStale) else {
                logger.notice("Dropped a folder bookmark that no longer resolves")
                continue
            }
            urls.append(url)
            kept.append(isStale ? (refreshedBookmark(for: url) ?? data) : data)
        }
        if kept.count != storedBookmarks.count || kept != storedBookmarks {
            defaults.set(kept, forKey: key)
        }
        return urls
    }

    /// Saves a bookmark for a folder the user just picked. The URL must still be accessible when called.
    func add(_ url: URL) throws {
        let data = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(storedBookmarks + [data], forKey: key)
    }

    func remove(_ url: URL) {
        let target = url.standardizedFileURL
        let remaining = storedBookmarks.filter { data in
            var isStale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: resolutionOptions, bookmarkDataIsStale: &isStale) else {
                return false
            }
            return resolved.standardizedFileURL != target
        }
        defaults.set(remaining, forKey: key)
    }

    private var storedBookmarks: [Data] {
        defaults.array(forKey: key) as? [Data] ?? []
    }

    private func refreshedBookmark(for url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
