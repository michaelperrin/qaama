import CoreImage
import Foundation
import Synchronization

/// The noise reduction a photo is decoded with, both amounts known, 0 to 1.
public nonisolated struct DenoiseAmounts: Hashable, Sendable {
    public var luminance: Double
    public var color: Double

    public static let none = DenoiseAmounts(luminance: 0, color: 0)

    public init(luminance: Double, color: Double) {
        self.luminance = luminance
        self.color = color
    }
}

/// A RAW file's decoder, kept after the first decode to decode the file again with other amounts
/// of noise reduction: that is a setting of Apple's RAW engine, which knows the sensor and the
/// sensitivity of the shot.
///
/// The same `CIRAWFilter` must be asked each time. Core Image keeps its demosaiced stage between
/// renders and only redoes the noise reduction: 6 to 20 ms for 26 MP (measured on an X-T4 file,
/// fitted in a 3000-pixel view), where a new filter on the same file decodes it all again, 250 to
/// 700 ms.
final nonisolated class RAWDecoder: Sendable {
    /// What the engine applies when nothing is asked: it varies with the file (none on luminance
    /// and half on color for a shot at base sensitivity). Zero for an amount the decoder can't set.
    let defaults: DenoiseAmounts
    /// False when the engine has no such setting for this file: that noise is then reduced on the
    /// decoded image, as for photos that are not RAW.
    private let setsLuminance: Bool
    private let setsColor: Bool
    /// `CIRAWFilter` is a mutable object: an image is asked for by setting its amounts, then reading
    /// its output, which the lock keeps together when two renders ask at once.
    private let filter: Mutex<CIRAWFilter>

    /// `filter` must be set for a full decode (no draft mode, scale of one) and is no longer the
    /// caller's to change.
    init(_ filter: sending CIRAWFilter) {
        setsLuminance = filter.isLuminanceNoiseReductionSupported
        setsColor = filter.isColorNoiseReductionSupported
        defaults = DenoiseAmounts(luminance: setsLuminance ? Double(filter.luminanceNoiseReductionAmount) : 0,
                                  color: setsColor ? Double(filter.colorNoiseReductionAmount) : 0)
        self.filter = Mutex(filter)
    }

    /// The file decoded with `amounts`; nil if the engine gives no image.
    func image(_ amounts: DenoiseAmounts) -> CIImage? {
        let decoded = filter.withLock { filter in
            if setsLuminance {
                filter.luminanceNoiseReductionAmount = Float(amounts.luminance)
            }
            if setsColor {
                filter.colorNoiseReductionAmount = Float(amounts.color)
            }
            // The image keeps the amounts the filter had when it was asked for.
            return filter.outputImage
        }
        guard let decoded else { return nil }
        let left = DenoiseAmounts(luminance: setsLuminance ? 0 : amounts.luminance, color: setsColor ? 0 : amounts.color)
        return DenoiseFilter.apply(left, to: decoded)
    }
}
