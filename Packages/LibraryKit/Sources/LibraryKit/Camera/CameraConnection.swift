import Foundation

/// A photo or a video on a card or a camera, as the device lists it: what the import grid shows
/// before anything is copied.
public nonisolated struct CameraFile: Identifiable, Hashable, Sendable {
    /// The file's place on the device ("DCIM/100CANON/IMG_0001.JPG"): unique there, and the same
    /// each time the card is read.
    public let id: String
    public var byteSize: Int64
    /// As the photo shows, orientation applied; 0 when the device doesn't say.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var creationDate: Date?
    public var isRAW: Bool
    public var isMovie: Bool

    public init(id: String, byteSize: Int64 = 0, pixelWidth: Int = 0, pixelHeight: Int = 0, creationDate: Date? = nil,
                isRAW: Bool = false, isMovie: Bool = false)
    {
        self.id = id
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.isRAW = isRAW
        self.isMovie = isMovie
    }

    /// The file's name, extension included.
    public var name: String {
        (id as NSString).lastPathComponent
    }

    /// The identifier without the extension: what a RAW and the JPEG shot with it share.
    var stem: String {
        (id as NSString).deletingPathExtension
    }
}

/// What a device tells while it is open.
public nonisolated enum CameraEvent: Sendable {
    /// Files found, as the device goes through its folders: often one at a time, in no useful order.
    case added([CameraFile])
    case removed([CameraFile.ID])
    /// The part of its files the device has announced so far, from 0 to 1, as it says itself.
    case progress(Double)
    /// Every file has been announced.
    case listed
    /// The device couldn't be opened or read; the sentence can be shown as it is.
    case failed(String)
}

/// What kind of device holds the photos, for the sidebar to tell them apart.
public nonisolated enum CameraDeviceKind: Sendable {
    /// A memory card in a reader.
    case card
    case phone
    case camera
}

/// A card or a camera that is plugged in, and what can be asked of it. Kept apart from
/// ImageCaptureCore so that what is built on it can be tested without a device.
///
/// A device answers one request at a time (measured, see `CameraRequestQueue`): callers go through
/// the queue rather than asking it directly.
public protocol CameraConnection: AnyObject {
    /// Unique among the devices plugged in.
    var id: String { get }
    var name: String { get }
    var kind: CameraDeviceKind { get }
    /// Told what `open()` finds, on the main actor. Set before opening.
    var onEvent: ((CameraEvent) -> Void)? { get set }
    /// Starts listing the files; the events follow. Opening twice does nothing more.
    func open()
    func close()
    /// The first bytes of a file, where its header and its embedded thumbnail are; nil when the
    /// device can't hand them over.
    func head(of id: CameraFile.ID, length: Int) async -> Data?
    /// An encoded image of the photo, `maxPixelSize` on its long edge, oriented for display. The
    /// device reads the whole file for it: about as slow as copying the photo.
    func thumbnailData(of id: CameraFile.ID, maxPixelSize: Int) async -> Data?
    /// Copies a file into `directory`, under its own name, and returns where the copy is. The
    /// directory must be one the app can write to without the user's leave (a temporary one).
    func download(_ id: CameraFile.ID, into directory: URL) async throws -> URL
    /// Ejects the device, so the card can be pulled out safely.
    func eject() async throws
    /// False for a device that can't delete, or a card whose lock is on. Known once it is listed.
    var canDelete: Bool { get }
    /// Deletes files from the device, for good, and returns those it did delete.
    func delete(_ ids: [CameraFile.ID]) async throws -> [CameraFile.ID]
}

/// Tells when cards and cameras are plugged in and pulled out.
public protocol CameraBrowser: AnyObject {
    var onConnect: ((any CameraConnection) -> Void)? { get set }
    /// With the `CameraConnection.id` of the device that left.
    var onDisconnect: ((String) -> Void)? { get set }
    /// The devices already plugged in are announced first.
    func start()
}
