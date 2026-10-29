import Foundation

/// What the header of an image file says, without decoding any pixel.
public nonisolated struct ImageMetadata: Hashable, Sendable {
    /// Dimensions as displayed, i.e. after the EXIF orientation is applied.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// EXIF orientation, 1 to 8 (1 = upright).
    public var orientation: Int
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var iso: Int?
    /// Seconds, e.g. 0.004 for 1/250 s.
    public var exposureTime: Double?
    /// F-number, e.g. 2.8.
    public var aperture: Double?
    /// Millimetres.
    public var focalLength: Double?

    public init(pixelWidth: Int, pixelHeight: Int, orientation: Int = 1, captureDate: Date? = nil, cameraMake: String? = nil,
                cameraModel: String? = nil, lens: String? = nil, iso: Int? = nil, exposureTime: Double? = nil,
                aperture: Double? = nil, focalLength: Double? = nil)
    {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.iso = iso
        self.exposureTime = exposureTime
        self.aperture = aperture
        self.focalLength = focalLength
    }
}
