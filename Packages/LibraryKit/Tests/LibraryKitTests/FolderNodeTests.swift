import Foundation
@testable import LibraryKit
import Testing

struct FolderNodeTests {
    @Test func buildsASortedTreeFromFilePaths() {
        let tree = FolderNode.tree(fromFilePaths: [
            "root.jpg", "2026/Lapland/a.raf", "2026/Lapland/b.raf", "2026/Oslo/c.jpg", "2025/d.jpg", "2026/e.jpg",
        ])
        #expect(tree.map(\.name) == ["2025", "2026"])
        #expect(tree[1].children.map(\.path) == ["2026/Lapland", "2026/Oslo"])
        #expect(tree[0].children.isEmpty)
    }

    @Test func rootOnlyFilesGiveNoNodes() {
        #expect(FolderNode.tree(fromFilePaths: ["a.jpg", "b.jpg"]).isEmpty)
    }

    @Test func folderScopeRestrictsTheCatalogStatement() async throws {
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Tree")
        try await store.save(folder)
        try await store.save([
            CatalogItem(folderID: folder.id, relativePath: "Trip/a.jpg", fileType: "public.jpeg", fileSize: 1, contentModified: .now),
            CatalogItem(folderID: folder.id, relativePath: "Trip/Day 1/b.jpg", fileType: "public.jpeg", fileSize: 1, contentModified: .now),
            CatalogItem(folderID: folder.id, relativePath: "Tripod/c.jpg", fileType: "public.jpeg", fileSize: 1, contentModified: .now),
        ])
        var query = LibraryQuery()
        query.folderPath = "Trip"
        let items = try await store.items(inFolder: folder.id, query: query)
        #expect(Set(items.map(\.fileName)) == ["a.jpg", "b.jpg"], "the prefix match must stop at the path separator")
        #expect(query.isUnfiltered, "a scope is not a filter")
        #expect(try await store.relativePaths(inFolder: folder.id).count == 3)
    }
}
