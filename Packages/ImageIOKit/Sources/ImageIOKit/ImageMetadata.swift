import Foundation

/// A place on Earth in degrees (WGS 84), positive towards north and east.
public nonisolated struct GeoCoordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// True when both name the same spot to about a meter (1e-5 degree): what survives a round trip
    /// through a header, a database or a map does not compare equal to the last digit.
    public func isAlmostEqual(to other: GeoCoordinate) -> Bool {
        abs(latitude - other.latitude) < 1e-5 && abs(longitude - other.longitude) < 1e-5
    }
}

/// A location the library holds over the one in a photo's own file: another place, or none at all.
/// Nil (no correction) leaves the file's word.
public nonisolated enum LocationCorrection: Hashable, Sendable {
    case place(GeoCoordinate)
    /// The photo has no location, whatever the file says.
    case removed

    /// The location a photo has once corrected.
    public var location: GeoCoordinate? {
        if case let .place(place) = self {
            return place
        }
        return nil
    }

    /// The correction that takes a photo whose file says `file` to `location`; nil when there is
    /// nothing to correct (the same place to about a meter, or no place on either side).
    public static func between(file: GeoCoordinate?, location: GeoCoordinate?) -> LocationCorrection? {
        switch (file, location) {
        case (nil, nil): nil
        case (.some, nil): .removed
        case let (file?, location?) where file.isAlmostEqual(to: location): nil
        case let (_, location?): .place(location)
        }
    }
}

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
    /// Where the photo was taken, when the camera or phone recorded it.
    public var location: GeoCoordinate?

    public init(pixelWidth: Int, pixelHeight: Int, orientation: Int = 1, captureDate: Date? = nil, cameraMake: String? = nil,
                cameraModel: String? = nil, lens: String? = nil, iso: Int? = nil, exposureTime: Double? = nil,
                aperture: Double? = nil, focalLength: Double? = nil, location: GeoCoordinate? = nil)
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
        self.location = location
    }
}
