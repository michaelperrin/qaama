import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

// Usage: skymask <model.mlmodelc> <out dir> <image>...
// For each image: runs Apple's DETR semantic segmentation (COCO panoptic classes) and reports the share of
// "sky (other)" pixels; writes <name>-detr-mask.png and <name>-detr-overlay.png. Then runs Vision's
// iterative (click) segmentation seeded at the top center of the image and writes <name>-click-mask.png.

let args = CommandLine.arguments
let modelURL = URL(filePath: args[1])
let outDir = URL(filePath: args[2])
let images = args.dropFirst(3).map { URL(filePath: $0) }
let context = CIContext()
let side = 448

let config = MLModelConfiguration()
config.computeUnits = .all
let loadStart = Date()
let model = try MLModel(contentsOf: modelURL, configuration: config)
print("model loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms")
let inputName = model.modelDescription.inputDescriptionsByName.keys.first!

var skyIndex = -1
for (_, value) in model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:] {
    if let data = value.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String]],
       let labels = parsed["labels"], let index = labels.firstIndex(of: "sky (other)") {
        skyIndex = index
    }
}
print("sky class index: \(skyIndex)")

func writePNG(_ image: CIImage, to url: URL) throws {
    try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

func maskImage(from pixels: [UInt8], width: Int, height: Int) -> CIImage {
    let data = Data(pixels)
    let provider = CGDataProvider(data: data as CFData)!
    let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    return CIImage(cgImage: cg)
}

func overlay(_ mask: CIImage, on image: CIImage) -> CIImage {
    let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.55)).cropped(to: image.extent)
    let blend = CIFilter(name: "CIBlendWithMask")!
    blend.setValue(red, forKey: kCIInputImageKey)
    blend.setValue(image, forKey: kCIInputBackgroundImageKey)
    blend.setValue(mask, forKey: kCIInputMaskImageKey)
    return blend.outputImage!
}

for url in images {
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        print("\(url.lastPathComponent): unreadable"); continue
    }
    let name = url.deletingPathExtension().lastPathComponent
    let width = image.extent.width, height = image.extent.height

    // --- DETR ---
    let resized = image.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / width, y: CGFloat(side) / height))
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    context.render(resized, to: buffer!, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    let start = Date()
    let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer!)]))
    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
    let predictions = output.featureValue(for: "semanticPredictions")!.multiArrayValue!
    var pixels = [UInt8](repeating: 0, count: side * side)
    var skyCount = 0
    for i in 0 ..< side * side where predictions[i].intValue == skyIndex {
        pixels[i] = 255; skyCount += 1
    }
    let share = Double(skyCount) / Double(side * side) * 100
    // Core ML rows start at the top; Core Image's origin is at the bottom.
    let detrMask = maskImage(from: pixels, width: side, height: side)
        .transformed(by: CGAffineTransform(scaleX: width / CGFloat(side), y: height / CGFloat(side)))
    print("\(url.lastPathComponent): \(Int(width))x\(Int(height)), DETR \(elapsed) ms, sky \(String(format: "%.1f", share))%")
    if share > 1 {
        try writePNG(detrMask, to: outDir.appendingPathComponent("\(name)-detr-mask.png"))
        try writePNG(overlay(detrMask, on: image), to: outDir.appendingPathComponent("\(name)-detr-overlay.png"))
    }

    // --- Vision click segmentation, seeded near the top center ---
    let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.92))
    if case .notReady = await request.assetStatus {
        print("  click segmentation assets not ready, downloading…")
        let reporter = ProgressManager(totalCount: 1)
        try await request.downloadAssets(progress: reporter.subprogress(assigningCount: 1))
    }
    let clickStart = Date()
    if let observation = try await request.perform(on: image) {
        let clickElapsed = Int(Date().timeIntervalSince(clickStart) * 1000)
        let clickMask = CIImage(cgImage: try observation.cgImage)
        let scaled = clickMask.transformed(by: CGAffineTransform(scaleX: width / clickMask.extent.width, y: height / clickMask.extent.height))
        print("  click segmentation \(clickElapsed) ms, mask \(Int(clickMask.extent.width))x\(Int(clickMask.extent.height))")
        try writePNG(overlay(scaled, on: image), to: outDir.appendingPathComponent("\(name)-click-overlay.png"))
    } else {
        print("  click segmentation returned nothing")
    }
}
