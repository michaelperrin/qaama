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

/// Everything that describes the file to write, independent of the edit. Remembered between exports.
public nonisolated struct ExportSettings: Codable, Sendable, Hashable {
    public var format: ExportFormat
    /// Lossy compression quality, 0…1; ignored by lossless formats.
    public var quality: Double
    public var size: ExportSize

    public static let qualityRange: ClosedRange<Double> = 0.3 ... 1

    public init(format: ExportFormat = .jpeg, quality: Double = 0.92, size: ExportSize = .original) {
        self.format = format
        self.quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
        self.size = size
    }
}
