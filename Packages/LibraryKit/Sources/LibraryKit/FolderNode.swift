import Foundation

/// A directory inside a library folder, with its subdirectories: the sidebar's tree.
public nonisolated struct FolderNode: Hashable, Sendable, Identifiable {
    /// Relative path from the folder root, e.g. `2026/Lapland`.
    public let path: String
    public var name: String {
        (path as NSString).lastPathComponent
    }

    public var children: [FolderNode]

    public var id: String {
        path
    }

    public init(path: String, children: [FolderNode] = []) {
        self.path = path
        self.children = children
    }

    /// Builds the tree of directories that contain the given relative file paths, sorted by name.
    /// Files at the root contribute no node.
    public static func tree(fromFilePaths paths: some Sequence<String>) -> [FolderNode] {
        var directories: Set<[String]> = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for depth in 1 ..< components.count {
                directories.insert(Array(components[0 ..< depth]))
            }
        }
        return build(prefix: [], from: directories)
    }

    private static func build(prefix: [String], from directories: Set<[String]>) -> [FolderNode] {
        directories
            .filter { $0.count == prefix.count + 1 && Array($0.dropLast()) == prefix }
            .sorted { $0.last!.localizedStandardCompare($1.last!) == .orderedAscending }
            .map { FolderNode(path: $0.joined(separator: "/"), children: build(prefix: $0, from: directories)) }
    }
}
