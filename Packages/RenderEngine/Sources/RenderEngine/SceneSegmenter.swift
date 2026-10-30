import CoreImage
import CoreML
import CoreVideo
import EditModel
import Foundation
import OSLog
import Synchronization
import Vision

/// Sky and scene-class masks: the bundled DETR model labels every pixel of a 448 × 448 copy, the
/// wanted classes become a coarse mask, and Vision's iterative segmentation refines its edges on the
/// analysis image, seeded with points inside and outside the coarse mask.
nonisolated enum SceneSegmenter {
    static let inputSide = 448
    /// Included and excluded seed points each; Vision caps the total it accepts.
    static let maximumSeedPoints = 4
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "SceneSegmenter")
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Qaama scene"])

    /// Set by the app to the compiled model in its bundle; nil leaves sky and scene masks unavailable.
    static let modelURL = Mutex<URL?>(nil)
    private static let loadedModel = Mutex<LoadedModel?>(nil)

    /// MLModel isn't declared Sendable but is documented as thread-safe for predictions.
    private final class LoadedModel: @unchecked Sendable {
        let model: MLModel
        let labels: [String]

        init(model: MLModel, labels: [String]) {
            self.model = model
            self.labels = labels
        }
    }

    enum SegmenterError: Error, LocalizedError {
        case modelMissing
        case unknownClass(String)
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .modelMissing: "The scene segmentation model isn't available."
            case let .unknownClass(label): "The model doesn't know the class “\(label)”."
            case .nothingFound: "None of that was found in this photo."
            }
        }
    }

    /// Mask of the given model labels over `analysis` (the reduced reference image).
    static func mask(for labels: [String], analysis: CIImage, handler: ImageRequestHandler) async throws -> CIImage {
        let loaded = try loadModel()
        let model = loaded.model, modelLabels = loaded.labels
        let indices = try labels.map { label -> Int32 in
            guard let index = modelLabels.firstIndex(of: label) else { throw SegmenterError.unknownClass(label) }
            return Int32(index)
        }
        let coarse = try predict(indices: Set(indices), model: model, analysis: analysis)
        guard coarse.coverage > 0.002 else { throw SegmenterError.nothingFound }
        // Fallback mask: plain non-uniform scaling to the analysis size, then a blur of about one model
        // pixel to hide the 448-px staircase.
        let scaleX = analysis.extent.width / CGFloat(inputSide), scaleY = analysis.extent.height / CGFloat(inputSide)
        let coarseImage = coarse.image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(scaleX, scaleY)) * 0.6)
            .cropped(to: analysis.extent)
        do {
            return try await refine(coarse: coarse, analysis: analysis, handler: handler)
        } catch {
            logger.notice("Edge refinement unavailable (\(error.localizedDescription, privacy: .public)); using the coarse mask")
            return coarseImage
        }
    }

    // MARK: - Model

    private static func loadModel() throws -> LoadedModel {
        if let loaded = loadedModel.withLock({ $0 }) {
            return loaded
        }
        guard let url = modelURL.withLock({ $0 }) else { throw SegmenterError.modelMissing }
        let clock = ContinuousClock()
        let start = clock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        var labels: [String] = []
        for (_, value) in model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:] {
            if let data = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String]],
               let list = parsed["labels"]
            {
                labels = list
            }
        }
        let loaded = LoadedModel(model: model, labels: labels)
        loadedModel.withLock { $0 = loaded }
        logger.notice("Loaded scene model (\(labels.count) labels) in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return loaded
    }

    struct CoarseMask {
        /// 448 × 448 mask, 255 where a wanted class was predicted.
        let pixels: [UInt8]
        let image: CIImage
        let coverage: Double
    }

    private static func predict(indices: Set<Int32>, model: MLModel, analysis: CIImage) throws -> CoarseMask {
        let side = inputSide
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw SegmenterError.modelMissing }
        let resized = analysis.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / analysis.extent.width, y: CGFloat(side) / analysis.extent.height))
        context.render(resized, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)]))
        guard let predictions = output.featureValue(for: "semanticPredictions")?.multiArrayValue else { throw SegmenterError.modelMissing }

        var pixels = [UInt8](repeating: 0, count: side * side)
        var hits = 0
        predictions.withUnsafeBufferPointer(ofType: Int32.self) { values in
            for index in 0 ..< min(values.count, pixels.count) where indices.contains(values[index]) {
                pixels[index] = 255
                hits += 1
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let cgImage = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return CoarseMask(pixels: pixels, image: CIImage(cgImage: cgImage), coverage: Double(hits) / Double(side * side))
    }

    // MARK: - Refinement

    /// Seeds Vision's click segmentation with points well inside the coarse mask (included) and well
    /// outside it (excluded), then returns its finer mask.
    /// Vision's iterative segmentation seeded with one point well inside the coarse mask. Extra
    /// included or excluded points make the request fail (status 14), so the seed is all it gets.
    private static func refine(coarse: CoarseMask, analysis _: CIImage, handler: ImageRequestHandler) async throws -> CIImage {
        let (inside, _) = seedPoints(from: coarse)
        guard let seed = inside.first else { throw SegmenterError.nothingFound }
        let request = GenerateIterativeSegmentationRequest(seedPoint: seed)
        request.qualityLevel = .accurate
        guard let observation = try await handler.perform(request) else { throw SegmenterError.nothingFound }
        return try CIImage(cgImage: observation.cgImage)
    }

    /// Up to 12 points on a grid, kept only where the coarse mask is uniform in a 5-pixel neighborhood
    /// (deep inside or clearly outside), in Vision's normalized coordinates (origin bottom-left).
    private static func seedPoints(from coarse: CoarseMask) -> (inside: [NormalizedPoint], outside: [NormalizedPoint]) {
        let side = inputSide
        var inside: [NormalizedPoint] = [], outside: [NormalizedPoint] = []
        let grid = 7
        for row in 0 ..< grid {
            for column in 0 ..< grid {
                let x = (column * 2 + 1) * side / (grid * 2), y = (row * 2 + 1) * side / (grid * 2)
                var sum = 0, count = 0
                for dy in stride(from: -6, through: 6, by: 3) {
                    for dx in stride(from: -6, through: 6, by: 3) {
                        let px = min(max(x + dx, 0), side - 1), py = min(max(y + dy, 0), side - 1)
                        sum += Int(coarse.pixels[py * side + px])
                        count += 1
                    }
                }
                let point = NormalizedPoint(x: Double(x) / Double(side), y: 1 - Double(y) / Double(side))
                if sum == 255 * count, inside.count < Self.maximumSeedPoints {
                    inside.append(point)
                } else if sum == 0, outside.count < Self.maximumSeedPoints {
                    outside.append(point)
                }
            }
        }
        return (inside, outside)
    }
}
