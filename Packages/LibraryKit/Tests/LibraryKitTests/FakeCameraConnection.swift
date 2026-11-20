import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import UniformTypeIdentifiers

/// A card that holds what the test puts on it, and remembers what it was asked.
@MainActor
final class FakeCameraConnection: CameraConnection {
    let id: String
    let name: String
    let kind = CameraDeviceKind.card
    var onEvent: ((CameraEvent) -> Void)?
    private(set) var isOpen = false
    /// Every request in the order received: "head <file>" or "thumbnail <file> <size>".
    private(set) var requests: [String] = []
    var heads: [CameraFile.ID: Data] = [:]
    var thumbnails: [CameraFile.ID: Data] = [:]
    /// The whole files, for the ones a test imports.
    var contents: [CameraFile.ID: Data] = [:]
    private(set) var isEjected = false

    init(id: String = "card", name: String = "EOS_DIGITAL") {
        self.id = id
        self.name = name
    }

    func open() {
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    /// What the device would announce.
    func send(_ event: CameraEvent) {
        onEvent?(event)
    }

    func head(of id: CameraFile.ID, length: Int) async -> Data? {
        requests.append("head \(id)")
        return heads[id].map { $0.prefix(length) }
    }

    func thumbnailData(of id: CameraFile.ID, maxPixelSize: Int) async -> Data? {
        requests.append("thumbnail \(id) \(maxPixelSize)")
        return thumbnails[id]
    }

    func download(_ id: CameraFile.ID, into directory: URL) async throws -> URL {
        requests.append("download \(id)")
        guard let data = contents[id] else { throw CameraImportError.notDownloaded((id as NSString).lastPathComponent) }
        let copy = directory.appendingPathComponent((id as NSString).lastPathComponent)
        try data.write(to: copy)
        return copy
    }

    func eject() async throws {
        isEjected = true
    }

    /// False as for a card whose lock is on.
    var canDelete = true
    /// Files the device refuses to delete.
    var undeletable: Set<CameraFile.ID> = []

    func delete(_ ids: [CameraFile.ID]) async throws -> [CameraFile.ID] {
        requests.append("delete \(ids.joined(separator: ", "))")
        let deleted = ids.filter { !undeletable.contains($0) }
        deleted.forEach { contents[$0] = nil }
        return deleted
    }
}

/// Announces the devices the test plugs in and pulls out.
@MainActor
final class FakeCameraBrowser: CameraBrowser {
    var onConnect: ((any CameraConnection) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private(set) var isStarted = false

    func start() {
        isStarted = true
    }
}

enum CameraTestImages {
    /// A JPEG of noise, so it doesn't compress to nothing, with or without the thumbnail a camera
    /// embeds in the header.
    static func jpeg(width: Int, height: Int, embeddingThumbnail: Bool) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        for index in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationEmbedThumbnail: embeddingThumbnail] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// Lets the main actor run until `condition` holds, or gives up after a second.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
