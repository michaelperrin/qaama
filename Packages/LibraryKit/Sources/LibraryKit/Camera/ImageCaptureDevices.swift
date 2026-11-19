#if canImport(ImageCaptureCore)
import Foundation
import ImageCaptureCore
import OSLog

/// The system's own way to cards and cameras (ImageCaptureCore, what Image Capture is made of).
///
/// In the sandbox it needs `com.apple.security.device.usb`, even for a card in the built-in
/// reader: without it no device is ever announced (measured, `Experiments/card-import`). The
/// card's volume itself stays out of reach: the device gives no path, everything is asked of it.
///
/// The delegate methods are called on the main thread, which is what lets them stay on the main
/// actor (`@preconcurrency`); the completion blocks of requests aren't always, so they are
/// `@Sendable` and only hand over values.
public final class ImageCaptureBrowser: NSObject, CameraBrowser, @preconcurrency ICDeviceBrowserDelegate {
    public var onConnect: ((any CameraConnection) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    private let browser = ICDeviceBrowser()
    private var connections: [ObjectIdentifier: ImageCaptureConnection] = [:]

    override public init() {
        super.init()
    }

    public func start() {
        browser.delegate = self
        // Cards and cameras plugged into this Mac; not the ones shared on the network.
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    public func deviceBrowser(_: ICDeviceBrowser, didAdd device: ICDevice, moreComing _: Bool) {
        guard let camera = device as? ICCameraDevice, connections[ObjectIdentifier(camera)] == nil else { return }
        let connection = ImageCaptureConnection(camera: camera)
        connections[ObjectIdentifier(camera)] = connection
        onConnect?(connection)
    }

    public func deviceBrowser(_: ICDeviceBrowser, didRemove device: ICDevice, moreGoing _: Bool) {
        guard let connection = connections.removeValue(forKey: ObjectIdentifier(device)) else { return }
        onDisconnect?(connection.id)
    }
}

/// One card or camera, through ImageCaptureCore.
final class ImageCaptureConnection: NSObject, CameraConnection, @preconcurrency ICCameraDeviceDelegate {
    let id: String
    let name: String
    let kind: CameraDeviceKind
    var onEvent: ((CameraEvent) -> Void)?

    private let camera: ICCameraDevice
    private var items: [CameraFile.ID: ICCameraFile] = [:]
    private var isOpen = false
    private var lastPercent = 0
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "ImageCaptureConnection")

    init(camera: ICCameraDevice) {
        self.camera = camera
        // A card has no identifier of its own that lasts; one per connection is all that is needed.
        id = camera.uuidString ?? UUID().uuidString
        name = camera.name ?? "Camera"
        if camera.transportType == ICDeviceTransport.transportTypeMassStorage.rawValue {
            kind = .card
        } else if let product = camera.productKind, product.hasPrefix("iPhone") || product.hasPrefix("iPad") {
            kind = .phone
        } else {
            kind = .camera
        }
        super.init()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        camera.delegate = self
        camera.requestOpenSession()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        camera.requestCloseSession()
        camera.delegate = nil
        items.removeAll()
    }

    func head(of id: CameraFile.ID, length: Int) async -> Data? {
        guard let item = items[id] else { return nil }
        let wanted = off_t(min(Int64(length), Int64(item.fileSize)))
        guard wanted > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            item.requestReadData(atOffset: 0, length: wanted) { @Sendable data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    func thumbnailData(of id: CameraFile.ID, maxPixelSize: Int) async -> Data? {
        guard let item = items[id] else { return nil }
        return await withCheckedContinuation { continuation in
            item.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixelSize]) { @Sendable data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    func download(_ id: CameraFile.ID, into directory: URL) async throws -> URL {
        guard let item = items[id] else { throw CameraImportError.notDownloaded((id as NSString).lastPathComponent) }
        let name = item.name ?? (id as NSString).lastPathComponent
        // The completion runs on any queue: only values cross.
        let saved: Result<String, any Error> = await withCheckedContinuation { continuation in
            _ = item.requestDownload(options: [.downloadsDirectoryURL: directory, .saveAsFilename: name, .overwrite: true]) { @Sendable saved, error in
                if let saved, error == nil {
                    continuation.resume(returning: .success(saved))
                } else {
                    continuation.resume(returning: .failure(error ?? CameraImportError.notDownloaded(name)))
                }
            }
        }
        return try directory.appendingPathComponent(saved.get())
    }

    var canDelete: Bool {
        !camera.isLocked && camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
    }

    func delete(_ ids: [CameraFile.ID]) async throws -> [CameraFile.ID] {
        let wanted = ids.compactMap { id in items[id].map { (id, $0) } }
        guard !wanted.isEmpty else { return [] }
        let paths = Dictionary(uniqueKeysWithValues: wanted.map { (ObjectIdentifier($0.1), $0.0) })
        // The completion runs on any queue: the items it names are told by identity, as values.
        let outcome: (deleted: [ObjectIdentifier], failure: (any Error)?) = await withCheckedContinuation { continuation in
            _ = camera.requestDeleteFiles(wanted.map(\.1), deleteFailed: { @Sendable _ in }, completion: { @Sendable result, error in
                let deleted = (result[.successful] ?? []).map { ObjectIdentifier($0) }
                continuation.resume(returning: (deleted, error))
            })
        }
        let deleted = outcome.deleted.compactMap { paths[$0] }
        if deleted.isEmpty, let failure = outcome.failure {
            throw failure
        }
        for id in deleted {
            items[id] = nil
        }
        return deleted
    }

    func eject() async throws {
        let failure: (any Error)? = await withCheckedContinuation { continuation in
            camera.requestEject { @Sendable error in continuation.resume(returning: error) }
        }
        if let failure {
            throw failure
        }
    }

    // MARK: Files

    /// The file's place on the device, from the names of the folders above it.
    private static func path(of item: ICCameraItem) -> String {
        var names = [item.name ?? ""]
        var folder = item.parentFolder
        while let current = folder {
            names.append(current.name ?? "")
            folder = current.parentFolder
        }
        return names.reversed().joined(separator: "/")
    }

    private func file(for item: ICCameraFile) -> CameraFile {
        CameraFile(id: Self.path(of: item), byteSize: Int64(item.fileSize), pixelWidth: item.width, pixelHeight: item.height,
                   creationDate: item.creationDate, isRAW: item.isRaw,
                   // The device only tells photos from videos: "public.image" or "public.movie".
                   isMovie: item.uti == "public.movie")
    }

    func cameraDevice(_: ICCameraDevice, didAdd added: [ICCameraItem]) {
        let files = added.compactMap { $0 as? ICCameraFile }.map { item in
            let file = file(for: item)
            items[file.id] = item
            return file
        }
        if !files.isEmpty {
            onEvent?(.added(files))
        }
        // In whole percents: told when it changes, not with every file.
        let percent = camera.contentCatalogPercentCompleted
        if percent != lastPercent {
            lastPercent = percent
            onEvent?(.progress(Double(percent) / 100))
        }
    }

    func cameraDevice(_: ICCameraDevice, didRemove removed: [ICCameraItem]) {
        let ids = removed.compactMap { $0 as? ICCameraFile }.map(Self.path(of:))
        for id in ids {
            items[id] = nil
        }
        if !ids.isEmpty {
            onEvent?(.removed(ids))
        }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog _: ICCameraDevice) {
        onEvent?(.listed)
    }

    // MARK: Session

    func device(_: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            onEvent?(.failed("“\(name)” couldn't be opened: \(error.localizedDescription)"))
        }
    }

    func device(_: ICDevice, didCloseSessionWithError error: (any Error)?) {
        if let error {
            logger.error("Closing \(self.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func device(_: ICDevice, didEncounterError error: (any Error)?) {
        logger.error("\(self.name, privacy: .public): \(error?.localizedDescription ?? "unknown error", privacy: .public)")
    }

    // The browser tells when the device leaves; the rest doesn't concern a card being read.
    func didRemove(_: ICDevice) {}
    func cameraDevice(_: ICCameraDevice, didReceiveThumbnail _: CGImage?, for _: ICCameraItem, error _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didReceiveMetadata _: [AnyHashable: Any]?, for _: ICCameraItem, error _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didRenameItems _: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_: ICCameraDevice) {}
    func cameraDevice(_: ICCameraDevice, didReceivePTPEvent _: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_: ICDevice) {}
}
#endif
