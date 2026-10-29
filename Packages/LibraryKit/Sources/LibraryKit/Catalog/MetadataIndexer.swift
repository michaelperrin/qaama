import Foundation
import ImageIOKit
import OSLog

/// Phase B of a scan: reads image headers for the items that still lack them, in batches, off the
/// main actor, and stores the result so the grid can refresh batch by batch.
///
/// Also computes the fingerprint while the file is open, so later scans can recognize copies.
public nonisolated struct MetadataIndexer: Sendable {
    public static let defaultBatchSize = 50
    /// Headers read concurrently within a batch; more mostly contends on disk.
    static let concurrency = 4

    private let store: CatalogStore
    private let batchSize: Int
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "MetadataIndexer")

    public init(store: CatalogStore, batchSize: Int = MetadataIndexer.defaultBatchSize) {
        self.store = store
        self.batchSize = batchSize
    }

    /// Reads every pending header of the folder. `preferred` is consulted before each batch so the
    /// caller can push the items currently on screen to the front. Returns the number of items read.
    /// Cancelling the task stops after the current batch.
    @discardableResult
    public func run(folder: CatalogFolder, at root: URL, preferred: @Sendable () -> Set<UUID> = { [] }) async throws -> Int {
        let clock = ContinuousClock()
        let start = clock.now
        var total = 0
        while !Task.isCancelled {
            let batch = try await store.itemsNeedingMetadata(inFolder: folder.id, limit: batchSize, preferring: preferred())
            if batch.isEmpty {
                break
            }
            let updated = await read(batch, root: root)
            try await store.save(updated)
            total += updated.count
        }
        if total > 0 {
            logger.notice("Read \(total) headers in \(folder.displayName, privacy: .public) in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        }
        return total
    }

    /// Reads the headers of a batch concurrently. An unreadable file keeps its item, marked as read so
    /// it isn't retried on every scan.
    func read(_ items: [CatalogItem], root: URL) async -> [CatalogItem] {
        await withTaskGroup(of: CatalogItem.self) { group in
            var pending = items.makeIterator()
            var results: [CatalogItem] = []
            results.reserveCapacity(items.count)

            func enqueue(_ item: CatalogItem) {
                group.addTask {
                    var item = item
                    let url = root.appendingPathComponent(item.relativePath)
                    do {
                        try item.apply(ImageMetadataReader.read(url))
                    } catch {
                        logger.error("Header unreadable for \(item.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    item.fingerprint = try? Fingerprint.compute(for: url, fileSize: item.fileSize, contentModified: item.contentModified)
                    item.metadataRead = .now
                    return item
                }
            }

            for _ in 0 ..< Self.concurrency {
                if let item = pending.next() {
                    enqueue(item)
                }
            }
            while let done = await group.next() {
                results.append(done)
                if let item = pending.next() {
                    enqueue(item)
                }
            }
            return results
        }
    }
}

nonisolated extension CatalogItem {
    mutating func apply(_ metadata: ImageMetadata) {
        pixelWidth = metadata.pixelWidth
        pixelHeight = metadata.pixelHeight
        orientation = metadata.orientation
        captureDate = metadata.captureDate
        cameraMake = metadata.cameraMake
        cameraModel = metadata.cameraModel
        lens = metadata.lens
        iso = metadata.iso
        exposureTime = metadata.exposureTime
        aperture = metadata.aperture
        focalLength = metadata.focalLength
    }
}
