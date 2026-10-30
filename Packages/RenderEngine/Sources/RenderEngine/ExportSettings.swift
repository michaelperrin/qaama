import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The file formats the exporter writes. All of them go through ImageIO; WebP is absent because
/// macOS doesn't encode it.
public nonisolated enum ExportFormat: String, Codable, CaseIterable, Sendable, Hashable {
    case jpeg, png, heic, avif

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        }
    }

    public var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        // UTType has no constant for AVIF; ImageIO knows the identifier.
        case .avif: UTType("public.avif") ?? .image
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .avif: "avif"
        }
    }

    /// Whether the quality setting applies.
    public var isLossy: Bool {
        self != .png
    }
}

/// How the exported image is sized, in pixels of the rendered (cropped) photo.
public nonisolated enum ExportSize: Codable, Sendable, Hashable {
    case original
    case width(Int)
    case height(Int)
    /// The image fits in a square of this side.
    case longEdge(Int)

    /// Output size for a rendered image of `source` pixels, rounded to whole pixels and never empty.
    public func outputSize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return source }
        let scale = self.scale(for: source)
        return CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
    }

    public func scale(for source: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0 else { return 1 }
        switch self {
        case .original: return 1
        case let .width(pixels): return CGFloat(max(1, pixels)) / source.width
        case let .height(pixels): return CGFloat(max(1, pixels)) / source.height
        case let .longEdge(pixels): return CGFloat(max(1, pixels)) / max(source.width, source.height)
        }
    }

    /// The pixel count the user typed, nil for the original size.
    public var pixels: Int? {
        switch self {
        case .original: nil
        case let .width(pixels), let .height(pixels), let .longEdge(pixels): pixels
        }
    }
}

/// An sRGB color with alpha, 0…1 components, free of platform color types.
public nonisolated struct ExportColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = ExportColor(red: 1, green: 1, blue: 1)
    public static let black = ExportColor(red: 0, green: 0, blue: 0)
}

/// A solid border around the exported photo. Sizes are fractions of the photo, so the same frame
/// looks the same on the preview and on the full-size file.
public nonisolated struct ExportFrame: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    /// Border thickness as a fraction of the photo's long edge.
    public var thickness: Double
    /// Width / height of the framed result; nil keeps an even border on every side. The border never
    /// gets thinner than `thickness`: the canvas grows on one axis to reach the ratio.
    public var aspectRatio: Double?
    /// Rounding of the photo's corners as a fraction of its short edge.
    public var cornerRadius: Double
    public var color: ExportColor

    public static let thicknessRange: ClosedRange<Double> = 0 ... 0.3
    public static let cornerRadiusRange: ClosedRange<Double> = 0 ... 0.5

    public init(isEnabled: Bool = false, thickness: Double = 0.05, aspectRatio: Double? = nil, cornerRadius: Double = 0, color: ExportColor = .white) {
        self.isEnabled = isEnabled
        self.thickness = thickness
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
        self.color = color
    }

    /// Where the photo sits in the framed canvas, in the photo's pixels.
    public func layout(for photo: CGSize) -> (canvas: CGSize, photoOrigin: CGPoint) {
        guard isEnabled, photo.width > 0, photo.height > 0 else { return (photo, .zero) }
        let border = (thickness * max(photo.width, photo.height)).rounded()
        var canvas = CGSize(width: photo.width + 2 * border, height: photo.height + 2 * border)
        if let aspectRatio, aspectRatio > 0 {
            if canvas.width / canvas.height < aspectRatio {
                canvas.width = (canvas.height * aspectRatio).rounded()
            } else {
                canvas.height = (canvas.width / aspectRatio).rounded()
            }
        }
        return (canvas, CGPoint(x: ((canvas.width - photo.width) / 2).rounded(), y: ((canvas.height - photo.height) / 2).rounded()))
    }
}

/// Everything that describes the file to write, independent of the edit. Remembered between exports.
public nonisolated struct ExportSettings: Codable, Sendable, Hashable {
    public var format: ExportFormat
    /// Lossy compression quality, 0…1; ignored by lossless formats.
    public var quality: Double
    /// Final size of the file, frame included.
    public var size: ExportSize
    public var frame: ExportFrame

    public static let qualityRange: ClosedRange<Double> = 0.3 ... 1

    public init(format: ExportFormat = .jpeg, quality: Double = 0.92, size: ExportSize = .original, frame: ExportFrame = ExportFrame()) {
        self.format = format
        self.quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
        self.size = size
        self.frame = frame
    }

    /// The settings that change how the picture looks, as opposed to how its file is written. The
    /// preview re-renders when they change.
    public var look: Look {
        Look(frame: frame)
    }

    public nonisolated struct Look: Hashable, Sendable {
        public var frame: ExportFrame
    }

    /// Pixel size of the output for a rendered photo of `photo` pixels: frame, then resizing.
    public func outputSize(for photo: CGSize) -> CGSize {
        size.outputSize(for: frame.layout(for: photo).canvas)
    }
}
