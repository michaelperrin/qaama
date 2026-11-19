import Foundation
import Observation
import OSLog

/// What tells a file already imported from a device: its name, its size and when the photo was
/// taken. A camera reuses names after 9,999 photos, and two cameras share them; the three together
/// are what a card being read again shows of a file, without opening it.
public nonisolated struct ImportedFileSignature: Hashable, Codable, Sendable {
    public var name: String
    public var byteSize: Int64
    /// Seconds since 1970, or nil when the device gave no date.
    public var captureTime: Int?

    public init(name: String, byteSize: Int64, captureDate: Date?) {
        self.name = name
        self.byteSize = byteSize
        captureTime = captureDate.map { Int($0.timeIntervalSince1970.rounded()) }
    }

    init(_ file: CameraFile) {
        self.init(name: file.name, byteSize: file.byteSize, captureDate: file.creationDate)
    }
}

/// One import, as it is remembered: where the photos went and which they are there.
public nonisolated struct ImportRecord: Hashable, Codable, Sendable, Identifiable {
    public enum Destination: Hashable, Codable, Sendable {
        case photos(albumID: String?)
        /// A folder of the sidebar, by its identifier in the catalog.
        case folder(id: UUID)
    }

    public var id: UUID
    public var date: Date
    public var deviceName: String
    public var destination: Destination
    /// The photos made in the Photos library, by identifier.
    public var photoIDs: [String]
    /// The image files copied into the folder, as paths relative to it.
    public var relativePaths: [String]

    public init(id: UUID = UUID(), date: Date = .now, deviceName: String, destination: Destination, photoIDs: [String] = [], relativePaths: [String] = []) {
        self.id = id
        self.date = date
        self.deviceName = deviceName
        self.destination = destination
        self.photoIDs = photoIDs
        self.relativePaths = relativePaths
    }

    /// How many photos or files the import brought.
    public var count: Int {
        photoIDs.count + relativePaths.count
    }
}

/// What was imported from cards and cameras so far: enough to tell, when a card is read again, the
/// photos it still holds that were imported already, and to show the last import again.
///
/// Kept in a JSON file of Application Support in the app, in memory in tests. User data, unlike the
/// catalog: nothing on disk says a photo came from a card, so it couldn't be rebuilt.
@Observable
public final class ImportHistory {
    public private(set) var lastImport: ImportRecord?
    /// Called when the files known as imported change, for the devices on screen to follow.
    @ObservationIgnored public var onChange: (() -> Void)?

    private var signatures: Set<ImportedFileSignature> = []
    private let fileURL: URL?
    @ObservationIgnored private var writing: Task<Void, Never>?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "ImportHistory")

    /// What the file holds.
    private nonisolated struct Saved: Codable, Sendable {
        var signatures: [ImportedFileSignature]
        var lastImport: ImportRecord?
    }

    /// Without a file nothing outlives the object: what tests and previews get.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// The file the app keeps the history in.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ImportHistory.json")
    }

    public func load() async {
        guard let fileURL else { return }
        let read = await Task.detached { () -> Result<Saved?, any Error> in
            guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .success(nil) }
            return Result { try JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL)) }
        }.value
        switch read {
        case let .success(saved):
            guard let saved else { return }
            // What was imported while the file was being read stays.
            signatures.formUnion(saved.signatures)
            lastImport = lastImport ?? saved.lastImport
            logger.notice("Loaded the import history: \(saved.signatures.count) files")
            onChange?()
        case let .failure(error):
            logger.error("Couldn't read the import history: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func contains(_ signature: ImportedFileSignature) -> Bool {
        signatures.contains(signature)
    }

    /// Remembers an import: its files count as imported from now on, and it becomes the last one.
    /// Undoing forgets it again, in the same step of the Edit menu as the undo the destination
    /// registers right before or after this call. `isRedoable` is false where the photos can't be
    /// brought back (the Photos library deletes them for good on undo).
    public func record(_ record: ImportRecord, files: [ImportedFileSignature], isRedoable: Bool = true, undoManager: UndoManager?) {
        let added = Set(files).subtracting(signatures)
        let previous = lastImport
        signatures.formUnion(added)
        lastImport = record
        changed()
        undoManager?.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                history.signatures.subtract(added)
                history.lastImport = previous
                history.changed()
                if isRedoable {
                    undoManager?.registerUndo(withTarget: history) { history in
                        MainActor.assumeIsolated { history.record(record, files: files, isRedoable: isRedoable, undoManager: undoManager) }
                    }
                }
            }
        }
    }

    /// Waits for the file to hold the last change, for tests.
    func settled() async {
        await writing?.value
    }

    private func changed() {
        onChange?()
        guard let fileURL else { return }
        let saved = Saved(signatures: Array(signatures), lastImport: lastImport)
        let logger = logger
        writing = Task.detached { [writing] in
            await writing?.value
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
            } catch {
                logger.error("Couldn't save the import history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
