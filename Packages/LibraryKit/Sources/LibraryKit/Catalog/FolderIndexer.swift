import Foundation
import OSLog
import UniformTypeIdentifiers

/// Outcome of indexing a folder, for logs and the UI.
public nonisolated struct IndexResult: Equatable, Sendable {
    public var listed = 0
    public var created = 0
    public var matched = 0
    public var missing = 0
}

/// Reconciles a folder on disk with the catalog (docs/catalogue.md §3 and §6, phase A).
///
/// Each listed file is matched to an existing item by, in order: the sidecar's identifier, the
/// system file identifier, the relative path, then the fingerprint. Unmatched files become new
/// items; items no longer on disk are marked missing.
public nonisolated struct FolderIndexer: Sendable {
    private let store: CatalogStore
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FolderIndexer")

    public init(store: CatalogStore) {
        self.store = store
    }

    public func index(folder: CatalogFolder, at url: URL) async throws -> IndexResult {
        let clock = ContinuousClock()
        let start = clock.now
        // Make sure the folder row exists: items reference it through a foreign key.
        try await store.save(folder)
        let files = try await Task.detached(priority: .userInitiated) { try FolderLister.list(url) }.value
        let existing = try await store.items(inFolder: folder.id, includeMissing: true)

        var byPath: [String: CatalogItem] = [:]
        var byFileIdentifier: [Data: CatalogItem] = [:]
        var byFingerprint: [String: CatalogItem] = [:]
        var byID: [UUID: CatalogItem] = [:]
        for item in existing {
            byPath[item.relativePath] = item
            byID[item.id] = item
            if let identifier = item.fileIdentifier {
                byFileIdentifier[identifier] = item
            }
            if let fingerprint = item.fingerprint {
                byFingerprint[fingerprint] = item
            }
        }

        var result = IndexResult(listed: files.count)
        var toSave: [CatalogItem] = []
        var claimed: Set<UUID> = []
        var presentIDs: Set<UUID> = []

        for file in files {
            // A sidecar is read only when it is new to us or changed since the last scan.
            var sidecar: Sidecar?
            var sidecarStatus: SidecarStatus = .unchanged
            if let sidecarDate = file.sidecarModified {
                let known = byPath[file.relativePath]?.sidecarModified
                if known == nil || known! < sidecarDate {
                    sidecar = try? Sidecar.read(forImageAt: file.url)
                    sidecarStatus = .changed(sidecarDate)
                }
            } else if byPath[file.relativePath]?.sidecarModified != nil {
                sidecarStatus = .removed
            }

            let match = resolve(file, sidecar: sidecar, byID: byID, byFileIdentifier: byFileIdentifier,
                                byPath: byPath, byFingerprint: byFingerprint, claimed: claimed)
            var item: CatalogItem
            if var found = match {
                found.relativePath = file.relativePath
                found.fileName = file.url.lastPathComponent
                found.fileType = file.fileType.identifier
                found.fileSize = file.fileSize
                found.contentModified = file.contentModified
                found.fileIdentifier = file.fileIdentifier ?? found.fileIdentifier
                found.isRAW = file.isRAW
                item = found
                result.matched += 1
            } else {
                // A sidecar identifier already used elsewhere means the file (and sidecar) were copied.
                let id = sidecar.map { byID[$0.id] == nil ? $0.id : UUID() } ?? UUID()
                item = CatalogItem(id: id, folderID: folder.id, relativePath: file.relativePath, fileType: file.fileType.identifier,
                                   fileSize: file.fileSize, contentModified: file.contentModified,
                                   fileIdentifier: file.fileIdentifier, isRAW: file.isRAW)
                result.created += 1
            }
            switch sidecarStatus {
            case .unchanged:
                break
            case let .changed(date):
                item.apply(sidecar, modified: date)
            case .removed:
                item.apply(nil, modified: nil)
            }
            claimed.insert(item.id)
            presentIDs.insert(item.id)
            toSave.append(item)
        }

        try await store.save(toSave)
        result.missing = try await store.reconcile(folderID: folder.id, presentIDs: presentIDs).count
        var updatedFolder = folder
        updatedFolder.lastScan = .now
        try await store.save(updatedFolder)
        logger.notice("Indexed \(folder.displayName, privacy: .public): \(result.listed) files, \(result.created) new, \(result.matched) matched, \(result.missing) newly missing, in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return result
    }

    private enum SidecarStatus {
        case unchanged
        case changed(Date)
        case removed
    }

    private func resolve(_ file: ListedFile, sidecar: Sidecar?, byID: [UUID: CatalogItem], byFileIdentifier: [Data: CatalogItem],
                         byPath: [String: CatalogItem], byFingerprint: [String: CatalogItem], claimed: Set<UUID>) -> CatalogItem?
    {
        let candidates: [CatalogItem?] = [
            sidecar.flatMap { byID[$0.id] },
            file.fileIdentifier.flatMap { byFileIdentifier[$0] },
            byPath[file.relativePath],
        ]
        for case let candidate? in candidates where !claimed.contains(candidate.id) {
            return candidate
        }
        // Last resort, only when fingerprints are known: a copy from another volume.
        if !byFingerprint.isEmpty,
           let fingerprint = try? Fingerprint.compute(for: file.url, fileSize: file.fileSize, contentModified: file.contentModified),
           let candidate = byFingerprint[fingerprint], !claimed.contains(candidate.id)
        {
            return candidate
        }
        return nil
    }
}

nonisolated extension CatalogItem {
    /// Copies the user decisions of a sidecar (or clears them when the sidecar is gone).
    mutating func apply(_ sidecar: Sidecar?, modified: Date?) {
        rating = sidecar?.rating ?? 0
        flag = sidecar?.flag ?? .none
        keywords = sidecar?.keywords ?? []
        hasEdit = sidecar?.recipeData != nil
        sidecarModified = modified
    }
}
