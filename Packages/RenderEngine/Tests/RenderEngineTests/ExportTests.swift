import CoreImage
import EditModel
import ImageIO
@testable import RenderEngine
import Testing
import UniformTypeIdentifiers

struct ExportTests {
    private let landscape = CGSize(width: 4000, height: 3000)

    @Test func sizesFollowTheChosenEdge() {
        #expect(ExportSize.original.outputSize(for: landscape) == landscape)
        #expect(ExportSize.width(2000).outputSize(for: landscape) == CGSize(width: 2000, height: 1500))
        #expect(ExportSize.height(600).outputSize(for: landscape) == CGSize(width: 800, height: 600))
        #expect(ExportSize.longEdge(1000).outputSize(for: landscape) == CGSize(width: 1000, height: 750))
        #expect(ExportSize.longEdge(1000).outputSize(for: CGSize(width: 3000, height: 4000)) == CGSize(width: 750, height: 1000))
        #expect(ExportSize.width(0).outputSize(for: landscape).width >= 1)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = ExportSettings(format: .avif, quality: 0.7, size: .longEdge(2048))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data) == settings)
        #expect(ExportSettings(quality: 2).quality == 1)
    }

    @Test func resizingProducesTheRequestedPixels() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 10, y: 20, width: 400, height: 300))
        let resized = ExportRenderer.resize(image, to: .width(200))
        #expect(resized.extent == CGRect(x: 0, y: 0, width: 200, height: 150))
        #expect(ExportRenderer.resize(image, to: .original).extent == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test(arguments: ExportFormat.allCases)
    func everyFormatEncodesAndReadsBack(format: ExportFormat) throws {
        let image = CIImage(color: CIColor(red: 0.9, green: 0.5, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = try ExportRenderer.encode(image, settings: ExportSettings(format: format, quality: 0.8))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(UTType(type)?.conforms(to: format.type) == true)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 48)
    }

    @Test func metadataIsCarriedOverWithTheOrientationReset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A rotated original with a camera model and a GPS block.
        let original = folder.appendingPathComponent("original.jpg")
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        let originalData = try ExportRenderer.encode(image, settings: ExportSettings(format: .jpeg), metadata: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        try originalData.write(to: original)

        let metadata = try #require(ExportRenderer.metadata(of: original))
        let exported = try ExportRenderer.encode(image, settings: ExportSettings(format: .jpeg), metadata: metadata)
        let source = try #require(CGImageSourceCreateWithData(exported as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "Test Camera")
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifFNumber] as? Double == 2.8)
        #expect((properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double == 48.85)
        #expect(properties[kCGImagePropertyOrientation] as? UInt32 == 1)
    }
}
