import CoreGraphics
import CoreImage
import EditModel
import Foundation
import OSLog
import Synchronization
import Vision

/// Computes the mask components that need a model: subject, background and people through Vision.
/// Sky and scene classes come with the segmentation model (next step).
///
/// Masks are computed on a reduced copy of the reference image (1024 px long edge) and scaled back,
/// so the cost doesn't grow with the photo. Each call runs on the Neural Engine, off the main actor.
public nonisolated enum ModelMasks {
    static let analysisSize: CGFloat = 1024

    /// Points the sky and scene masks at the compiled segmentation model (set once by the app).
    public static func useSceneModel(at url: URL?) {
        SceneSegmenter.modelURL.withLock { $0 = url }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Qaama masks"])
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "ModelMasks")

    public enum ResolveError: Error, LocalizedError {
        case noSubjectFound
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .noSubjectFound: "No subject was found in this photo."
            case let .unavailable(kind): "The \(kind) mask isn't available yet."
            }
        }
    }

    /// The mask image for a component, covering the reference image, or nil for kinds that need no model.
    public static func resolve(_ kind: MaskKind, reference: CIImage) async throws -> CIImage? {
        guard kind.needsModel else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let (analysis, handler) = try makeHandler(for: reference)
        let mask: CIImage
        switch kind {
        case let .subject(instances):
            mask = try await subjectMask(handler: handler, analysis: analysis, instances: instances)
        case .background:
            mask = try await subjectMask(handler: handler, analysis: analysis, instances: nil)
                .applyingFilter("CIColorInvert").cropped(to: analysis.extent)
        case .people:
            let request = GeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            let observation = try await handler.perform(request)
            mask = try CIImage(cgImage: observation.cgImage)
        case .sky:
            mask = try await SceneSegmenter.mask(for: [SceneClasses.sky.label], analysis: analysis, handler: handler)
        case let .scene(classes):
            mask = try await SceneSegmenter.mask(for: classes, analysis: analysis, handler: handler)
        default:
            return nil
        }
        let scaled = scale(mask, toFill: reference.extent)
        logger.notice("Resolved \(kind.displayName, privacy: .public) mask in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return scaled
    }

    /// Resolves every model-based component of a recipe, for renders that start without a cache.
    public static func resolveAll(in recipe: EditRecipe, reference: CIImage, existing: [UUID: CIImage] = [:]) async -> [UUID: CIImage] {
        var resolved = existing
        for layer in recipe.layers where layer.isEnabled {
            for component in layer.mask?.components ?? [] where component.kind.needsModel && resolved[component.id] == nil {
                do {
                    if let image = try await resolve(component.kind, reference: reference) {
                        resolved[component.id] = image
                    }
                } catch {
                    logger.error("Mask \(component.kind.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return resolved
    }

    // MARK: - Helpers

    private static func subjectMask(handler: ImageRequestHandler, analysis _: CIImage, instances: [Int]?) async throws -> CIImage {
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()) else {
            throw ResolveError.noSubjectFound
        }
        let wanted = instances.map { IndexSet($0.filter(observation.allInstances.contains)) } ?? observation.allInstances
        guard !wanted.isEmpty else { throw ResolveError.noSubjectFound }
        let buffer = try observation.generateScaledMask(for: wanted, scaledToImageFrom: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Reduced copy of the reference as a CGImage, and the Vision handler on it.
    private static func makeHandler(for reference: CIImage) throws -> (CIImage, ImageRequestHandler) {
        let extent = reference.extent
        let scale = min(1, analysisSize / max(extent.width, extent.height))
        let analysis = reference.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).movedToOrigin()
        guard let cgImage = context.createCGImage(analysis, from: analysis.extent) else {
            throw ResolveError.unavailable("analysis image")
        }
        return (analysis, ImageRequestHandler(cgImage))
    }

    /// Scales a mask so it covers `extent` exactly (masks come back at the analysis size).
    private static func scale(_ mask: CIImage, toFill extent: CGRect) -> CIImage {
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return mask }
        let transform = CGAffineTransform(scaleX: extent.width / maskExtent.width, y: extent.height / maskExtent.height)
        // Models leave their outermost rows and columns soft: trim them and replicate the next ones
        // outward, so the mask reaches the image border without a faint unselected line.
        let origin = mask.movedToOrigin()
        let trimmed = origin.cropped(to: origin.extent.insetBy(dx: 2, dy: 2)).clampedToExtent().cropped(to: origin.extent)
        return trimmed.transformed(by: transform).clampedToExtent().cropped(to: extent)
    }
}
