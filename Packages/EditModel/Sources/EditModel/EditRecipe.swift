import Foundation

/// The non-destructive edit applied to a photo: retouches, then a list of adjustment layers, never
/// pixels.
///
/// Serialized as JSON and stored next to the photo (sidecar file or Photos adjustment data),
/// so the original is untouched and the edit can be reopened or reset at any time.
/// The first layer is the global one and never has a mask; later layers may carry one.
public struct EditRecipe: Codable, Hashable, Sendable {
    /// Bumped when the meaning of the document changes; readers refuse other versions.
    public static let currentVersion = 2

    public var version: Int
    public var layers: [AdjustmentLayer]
    /// Straighten, rotate and crop; nil when untouched.
    public var geometry: Geometry?
    /// What was painted out of the original, in order, before anything else applies.
    public var retouches: [Retouch] = []

    public static let identity = EditRecipe()

    public init(adjustments: AdjustmentSet = AdjustmentSet()) {
        version = Self.currentVersion
        layers = [AdjustmentLayer(adjustments: adjustments)]
    }

    /// Shortcut for the global layer's basic adjustments.
    public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0) {
        self.init(adjustments: AdjustmentSet(exposure: exposure, contrast: contrast, saturation: saturation))
    }

    /// The global layer's adjustments, the ones most of the UI edits.
    public var global: AdjustmentSet {
        get { layers.first?.adjustments ?? AdjustmentSet() }
        set {
            if layers.isEmpty {
                layers = [AdjustmentLayer(adjustments: newValue)]
            } else {
                layers[0].adjustments = newValue
            }
        }
    }

    /// True when applying the recipe would leave the photo unchanged. A masked layer counts only when
    /// it has both adjustments and a mask that selects something.
    public var isIdentity: Bool {
        retouches.isEmpty && (geometry?.isIdentity ?? true) && layers.allSatisfy { layer in
            !layer.isEnabled || layer.adjustments.isIdentity || (layer.mask?.isEmpty ?? false)
        }
    }

    /// Layers after the global one.
    public var maskedLayers: [AdjustmentLayer] {
        Array(layers.dropFirst())
    }

    // MARK: - Serialization

    private enum CodingKeys: String, CodingKey {
        case version, layers, geometry, retouches
    }

    /// Retouches are absent from the documents of photos that have none, so those documents are
    /// what they were before retouching existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        layers = try container.decode([AdjustmentLayer].self, forKey: .layers)
        geometry = try container.decodeIfPresent(Geometry.self, forKey: .geometry)
        retouches = try container.decodeIfPresent([Retouch].self, forKey: .retouches) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(layers, forKey: .layers)
        try container.encodeIfPresent(geometry, forKey: .geometry)
        if !retouches.isEmpty {
            try container.encode(retouches, forKey: .retouches)
        }
    }

    public enum DecodingError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        // Peek at the version first so an old or newer document gives a clear error, not a key mismatch.
        let header = try decoder.decode(VersionHeader.self, from: jsonData)
        guard header.version == Self.currentVersion else {
            throw DecodingError.unsupportedVersion(header.version ?? 0)
        }
        var decoded = try decoder.decode(EditRecipe.self, from: jsonData)
        if decoded.layers.isEmpty {
            decoded.layers = [AdjustmentLayer()]
        }
        for index in decoded.layers.indices {
            decoded.layers[index].adjustments.clamp()
        }
        if let geometry = decoded.geometry {
            // Re-run the initializer's clamping on what came from disk; drop it when it does nothing.
            let clean = Geometry(angle: geometry.angle, quarterTurns: geometry.quarterTurns, isFlippedHorizontally: geometry.isFlippedHorizontally,
                                 crop: geometry.crop, aspectRatio: geometry.aspectRatio)
            decoded.geometry = clean.isIdentity ? nil : clean
        }
        self = decoded
    }

    private struct VersionHeader: Decodable {
        var version: Int?
    }
}

/// A set of adjustments, optionally restricted to a masked region, that can be switched off.
public struct AdjustmentLayer: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    /// Where the adjustments apply; nil means the whole image.
    public var mask: Mask?
    public var adjustments: AdjustmentSet

    public init(id: UUID = UUID(), isEnabled: Bool = true, mask: Mask? = nil, adjustments: AdjustmentSet = AdjustmentSet()) {
        self.id = id
        self.isEnabled = isEnabled
        self.mask = mask
        self.adjustments = adjustments
    }
}
