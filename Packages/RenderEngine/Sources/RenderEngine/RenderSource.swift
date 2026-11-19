import CoreGraphics
import CoreImage
import EditModel
import Foundation
import UniformTypeIdentifiers

/// Where the pixels of a photo come from.
public nonisolated enum RenderSource: Sendable {
    /// A file on disk, RAW or not. RAW files go through Apple's RAW engine (`CIRAWFilter`).
    case file(URL)
    /// An already decoded image, as PhotoKit hands them out.
    case image(CGImage)
}

/// A decoded photo ready for the pipeline, plus what the UI needs to know about it.
public nonisolated struct SourceImage: Sendable {
    /// The photo at full resolution, as it is decoded when nothing is asked: the original. What a
    /// recipe is applied to is `image(denoise:)`.
    public let image: CIImage
    /// The pixels of a quick stand-in for `image`, for photos that are slow to decode: a RAW's draft
    /// decode at reduced scale, by the same RAW engine, so colors match. Smaller than `image`; use
    /// `draft` to show it. Nil when `image` is quick itself. It never carries a recipe's noise
    /// reduction: it is on screen for a moment, at a scale that hides the noise anyway.
    public let draftPixels: CIImage?
    public let isRAW: Bool
    /// Decodes a RAW again with other amounts of noise reduction; nil for other images.
    private let decoder: RAWDecoder?
    public var pixelSize: CGSize {
        image.extent.size
    }

    /// `draftPixels` stretched to the extent of `image`, so the pipeline can't tell it from the
    /// real thing: masks, crops and pixel-sized filters land where they will on it.
    public var draft: CIImage? {
        draftPixels.map { SourceImageLoader.stretched($0, to: image.extent) }
    }

    public init(image: CIImage, draftPixels: CIImage? = nil, isRAW: Bool) {
        self.init(image: image, draftPixels: draftPixels, isRAW: isRAW, decoder: nil)
    }

    init(image: CIImage, draftPixels: CIImage?, isRAW: Bool, decoder: RAWDecoder?) {
        self.image = image
        self.draftPixels = draftPixels
        self.isRAW = isRAW
        self.decoder = decoder
    }

    /// The same photo with other draft pixels, typically the same ones already decoded.
    public func withDraftPixels(_ pixels: CIImage) -> SourceImage {
        SourceImage(image: image, draftPixels: pixels, isRAW: isRAW, decoder: decoder)
    }

    // MARK: - Noise reduction

    /// The noise reduction `image` was decoded with, which is where the sliders stand until they
    /// are moved: what the RAW engine picks for the file, none for other images.
    public var defaultDenoise: DenoiseAmounts {
        decoder?.defaults ?? .none
    }

    /// The amounts `denoise` stands for on this photo: its own, the photo's defaults for the rest.
    public func amounts(of denoise: Denoise?) -> DenoiseAmounts {
        DenoiseAmounts(luminance: denoise?.luminance ?? defaultDenoise.luminance, color: denoise?.color ?? defaultDenoise.color)
    }

    /// The photo at full resolution with `denoise` (a recipe's `sourceDenoise`): what the pipeline
    /// takes. A RAW is decoded again by its engine, other images are filtered (`DenoiseFilter`).
    ///
    /// Each call makes a new image, and one image per position of a slider must not be marked as an
    /// intermediate to cache: 200 MB each for 26 MP (measured: 6 GB after forty positions, and
    /// renders of 25 to 260 ms instead of 18). An image used again is kept by Core Image by itself.
    public func image(denoise: Denoise?) -> CIImage {
        let amounts = amounts(of: denoise)
        guard amounts != defaultDenoise else { return image }
        guard let decoder else { return DenoiseFilter.apply(amounts, to: image) }
        return decoder.image(amounts) ?? image
    }
}

/// Decodes a `RenderSource` into a `CIImage`. Decoding is lazy in Core Image, but RAW demosaicing is
/// expensive, so the result is marked as a cacheable intermediate: the pipeline downstream re-runs on
/// every slider change, the RAW stage does not.
public nonisolated enum SourceImageLoader {
    public enum LoadError: Error, LocalizedError {
        case unreadable(URL)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(url): "The image “\(url.lastPathComponent)” can't be decoded."
            }
        }
    }

    public static func load(_ source: RenderSource) throws -> SourceImage {
        switch source {
        case let .image(cgImage):
            return SourceImage(image: CIImage(cgImage: cgImage).insertingIntermediate(cache: true), isRAW: false)
        case let .file(url):
            if isRAW(url), let raw = CIRAWFilter(imageURL: url) {
                // An output image keeps the settings the filter had when it was asked for, so one
                // filter (50 ms to set up) gives both the draft and the full decode.
                raw.isDraftModeEnabled = true
                raw.scaleFactor = draftScale
                let draft = raw.outputImage
                raw.isDraftModeEnabled = false
                raw.scaleFactor = 1
                if let output = raw.outputImage {
                    let full = output.insertingIntermediate(cache: true)
                    // The filter stays with the photo: its noise reduction is set through it.
                    return SourceImage(image: full, draftPixels: draft?.insertingIntermediate(cache: true), isRAW: true, decoder: RAWDecoder(raw))
                }
            }
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw LoadError.unreadable(url)
            }
            return SourceImage(image: image.insertingIntermediate(cache: true), isRAW: false)
        }
    }

    /// Scale of a RAW's draft decode. Measured on a 26 MP X-Trans file: about 100 ms at half scale
    /// in draft mode against 250 to 450 ms for the full decode; a quarter is no faster, and half
    /// still fills a 3000-pixel-wide canvas.
    static let draftScale: Float = 0.5

    /// `draft` scaled to cover `extent` exactly, so it can stand in for the image of that extent.
    static func stretched(_ draft: CIImage, to extent: CGRect) -> CIImage {
        guard draft.extent.width > 0, draft.extent.height > 0, !draft.extent.isInfinite else { return draft }
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: extent.width / draft.extent.width, y: extent.height / draft.extent.height)
            .translatedBy(x: -draft.extent.minX, y: -draft.extent.minY)
        return draft.transformed(by: transform).cropped(to: extent)
    }

    public static func isRAW(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }
}
