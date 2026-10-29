import Foundation

/// The `<image>.qaama` file next to a photo: the portable truth about what the user decided
/// (identity, rating, flag, keywords, edit recipe). See `docs/catalogue.md` §5.
///
/// Serialized by hand with `JSONSerialization` so the recipe, owned by another package, is embedded
/// as a JSON object rather than an opaque string. No backward compatibility while the app is young:
/// files without the current structure are reported as malformed.
public nonisolated struct Sidecar: Hashable, Sendable {
    public static let currentVersion = 2

    public var id: UUID
    public var rating: Int
    public var flag: ItemFlag
    public var keywords: [String]
    /// The edit recipe as JSON (an object), or nil when the photo has no edit.
    public var recipeData: Data?

    public init(id: UUID = UUID(), rating: Int = 0, flag: ItemFlag = .none, keywords: [String] = [], recipeData: Data? = nil) {
        self.id = id
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.keywords = keywords
        self.recipeData = recipeData
    }

    /// True when nothing is worth keeping: the file should then be deleted, not written.
    public var isEmpty: Bool {
        rating == 0 && flag == .none && keywords.isEmpty && recipeData == nil
    }

    public enum ReadError: Error, LocalizedError, Equatable {
        case malformed(URL)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case let .malformed(url): "The sidecar “\(url.lastPathComponent)” isn't valid."
            case let .unsupportedVersion(version): "This sidecar was written by a newer Qaama (format \(version))."
            }
        }
    }

    // MARK: - Files

    public static func url(for imageURL: URL) -> URL {
        EditingFormat.sidecarURL(for: imageURL)
    }

    /// Reads the sidecar of an image, or nil when there is none.
    public static func read(forImageAt imageURL: URL) throws -> Sidecar? {
        let url = url(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try Sidecar(data: Data(contentsOf: url), url: url)
    }

    /// Writes the sidecar next to the image, or removes it when there is nothing to keep.
    public func write(forImageAt imageURL: URL) throws {
        let url = Self.url(for: imageURL)
        if isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try jsonData().write(to: url, options: .atomic)
        }
    }

    // MARK: - JSON

    public init(data: Data, url: URL? = nil) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.malformed(url ?? URL(filePath: "/"))
        }
        let version = object["version"] as? Int ?? 0
        guard version <= Self.currentVersion else { throw ReadError.unsupportedVersion(version) }
        guard let idString = object["id"] as? String, let id = UUID(uuidString: idString) else {
            throw ReadError.malformed(url ?? URL(filePath: "/"))
        }
        let recipe = try (object["recipe"] as? [String: Any]).map(Self.canonical)
        self.init(
            id: id,
            rating: object["rating"] as? Int ?? 0,
            flag: ItemFlag(sidecarName: object["flag"] as? String),
            keywords: object["keywords"] as? [String] ?? [],
            recipeData: recipe
        )
    }

    public func jsonData() throws -> Data {
        var object: [String: Any] = [
            "version": Self.currentVersion,
            "id": id.uuidString,
        ]
        if rating != 0 {
            object["rating"] = rating
        }
        if flag != .none {
            object["flag"] = flag.sidecarName
        }
        if !keywords.isEmpty {
            object["keywords"] = keywords
        }
        if let recipeData {
            guard let recipe = try? JSONSerialization.jsonObject(with: recipeData) as? [String: Any] else {
                throw ReadError.malformed(URL(filePath: "/"))
            }
            object["recipe"] = recipe
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Re-serializes a JSON object with sorted keys so equal recipes give equal bytes.
    private static func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

nonisolated extension ItemFlag {
    /// Human-readable spelling used in sidecars, unlike the integer stored in the catalog.
    var sidecarName: String {
        switch self {
        case .picked: "pick"
        case .rejected: "reject"
        case .none: "none"
        }
    }

    init(sidecarName: String?) {
        switch sidecarName {
        case "pick": self = .picked
        case "reject": self = .rejected
        default: self = .none
        }
    }
}
