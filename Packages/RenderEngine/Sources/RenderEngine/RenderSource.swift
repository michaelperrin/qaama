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
    /// A reduced copy of `image`, for the screen: the editor works on it for as long as the screen
    /// asks for no more pixels than it holds, since every stage of the pipeline costs memory and
    /// time in proportion to the pixels it is given (measured on 26 MP: 4.5 GB and 13 ms per slider
    /// move at full size, 1.4 GB and 4 ms on the half). A RAW's is decoded at that scale by the same
    /// RAW engine, so colors match. Nil for a photo too small to gain anything. It never carries a
    /// recipe's noise reduction: a recipe that sets one is rendered on `image(denoise:)`.
    public let proxy: CIImage?
    /// True when `proxy` is pixels already decoded (`withProxy`), which can be drawn at once
    /// whatever Core Image has kept or let go of in the meantime.
    public let holdsProxyPixels: Bool
    public let isRAW: Bool
    /// Decodes a RAW again with other amounts of noise reduction; nil for other images.
    private let decoder: RAWDecoder?
    public var pixelSize: CGSize {
        image.extent.size
    }

    /// Pixels of `proxy` per pixel of `image`: what the pipeline is told when it is given the proxy
    /// (`RenderPipeline.apply`'s `scale`). Nil without a proxy.
    public var proxyScale: CGFloat? {
        guard let proxy, image.extent.width > 0 else { return nil }
        return proxy.extent.width / image.extent.width
    }

    public init(image: CIImage, proxy: CIImage? = nil, isRAW: Bool) {
        self.init(image: image, proxy: proxy, isRAW: isRAW, decoder: nil)
    }

    init(image: CIImage, proxy: CIImage?, isRAW: Bool, decoder: RAWDecoder?, holdsProxyPixels: Bool = false) {
        self.image = image
        self.proxy = proxy
        self.holdsProxyPixels = holdsProxyPixels
        self.isRAW = isRAW
        self.decoder = decoder
    }

    /// The same photo with its proxy decoded into pixels (`CanvasRenderer.rasterized`).
    public func withProxy(_ pixels: CIImage) -> SourceImage {
        SourceImage(image: image, proxy: pixels, isRAW: isRAW, decoder: decoder, holdsProxyPixels: true)
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

/// Decodes a `RenderSource` into a `CIImage` and its proxy. Decoding is lazy in Core Image, but RAW
/// demosaicing is expensive, so the results are marked as cacheable intermediates: the pipeline
/// downstream re-runs on every slider change, the RAW stage does not.
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
            return plain(CIImage(cgImage: cgImage))
        case let .file(url):
            if isRAW(url), let raw = CIRAWFilter(imageURL: url) {
                // An output image keeps the settings the filter had when it was asked for, so one
                // filter (50 ms to set up) gives both the proxy and the full decode.
                raw.scaleFactor = Float(proxyScale)
                let reduced = raw.outputImage
                raw.scaleFactor = 1
                if let output = raw.outputImage {
                    let full = output.insertingIntermediate(cache: true)
                    let proxy = hasProxy(full.extent.size) ? reduced?.insertingIntermediate(cache: true) : nil
                    // The filter stays with the photo: its noise reduction is set through it.
                    return SourceImage(image: full, proxy: proxy, isRAW: true, decoder: RAWDecoder(raw))
                }
            }
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw LoadError.unreadable(url)
            }
            return plain(image)
        }
    }

    /// A photo that is not a RAW: its proxy is the image itself, reduced.
    private static func plain(_ decoded: CIImage) -> SourceImage {
        let image = decoded.insertingIntermediate(cache: true)
        guard hasProxy(image.extent.size) else { return SourceImage(image: image, isRAW: false) }
        // Whole pixels: a fractional extent would leave a half-transparent row at the edge.
        let size = CGSize(width: (image.extent.width * proxyScale).rounded(.down), height: (image.extent.height * proxyScale).rounded(.down))
        let reduced = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
            .cropped(to: CGRect(origin: .zero, size: size))
        return SourceImage(image: image, proxy: reduced.insertingIntermediate(cache: true), isRAW: false)
    }

    /// Scale of a photo's proxy. For a RAW, measured on three 26 MP X-Trans files: decoding at half
    /// scale takes 230 to 340 ms and 0.7 GB, where decoding in full and reducing takes 250 to 450 ms
    /// and 1.5 GB; the engine's draft mode is no faster at that scale and further from the full
    /// decode (1.4 against 1.2 levels of 255 on average), so it is not used. Half of a 26 MP photo
    /// still fills a canvas 3000 pixels wide.
    static let proxyScale: CGFloat = 0.5

    /// Long edge under which a photo gets no proxy: it is cheap as it is, and its half would not
    /// fill a canvas.
    static let smallestLongEdgeWithProxy: CGFloat = 2048

    static func hasProxy(_ size: CGSize) -> Bool {
        max(size.width, size.height) >= smallestLongEdgeWithProxy
    }

    public static func isRAW(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }
}
