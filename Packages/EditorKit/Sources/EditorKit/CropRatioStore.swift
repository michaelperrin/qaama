import Foundation
import Observation
import OSLog

/// An aspect ratio the crop can be locked to, as the two numbers the user reads: 3:2, 2.39:1.
/// The order matters: 2:3 is the upright frame of 3:2. The user may give it a name of their own
/// ("A4"), shown instead of the numbers.
public nonisolated struct CropRatio: Codable, Hashable, Sendable, Identifiable {
    public let width: Double
    public let height: Double
    /// The name the user gave it; nil for a ratio named by its numbers.
    public let label: String?

    /// Ratios outside this range leave a frame too thin to drag.
    public static let valueRange: ClosedRange<Double> = 0.1 ... 10
    /// Two ratios closer than this are the same one: 1.5 and 3:2, or a photo's own ratio in pixels.
    public static let tolerance = 0.001

    /// The ratios the app comes with, always listed.
    public static let builtIn: [CropRatio] = [(1, 1), (3, 2), (4, 3), (16, 9), (5, 4)].compactMap { CropRatio(width: $0.0, height: $0.1) }

    /// Nil when a side isn't a positive number or the ratio is out of `valueRange`.
    /// A blank `label` is no label.
    public init?(width: Double, height: Double, label: String? = nil) {
        guard width.isFinite, height.isFinite, width > 0, height > 0, Self.valueRange.contains(width / height) else { return nil }
        self.width = width
        self.height = height
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = trimmed.isEmpty ? nil : trimmed
    }

    /// Reads what a user types: "7:5", "7 x 5", "7/5", "2,39:1", or one number for a ratio to 1.
    public init?(parsing text: String, label: String? = nil) {
        // Empty parts are kept, so that "7:" isn't read as 7.
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { ":x×/".contains($0.lowercased()) }).map { part in
            Double(part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        switch parts.count {
        case 1:
            guard let value = parts[0] else { return nil }
            self.init(width: value, height: 1, label: label)
        case 2:
            guard let width = parts[0], let height = parts[1] else { return nil }
            self.init(width: width, height: height, label: label)
        default:
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let ratio = try CropRatio(width: container.decode(Double.self, forKey: .width), height: container.decode(Double.self, forKey: .height),
                                        label: container.decodeIfPresent(String.self, forKey: .label))
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a usable crop ratio"))
        }
        self = ratio
    }

    /// Width / height, what `Geometry.aspectRatio` holds.
    public var value: Double {
        width / height
    }

    /// The numbers, not the name: two ratios may be given the same name, never the same frame.
    public var id: String {
        "\(width):\(height)"
    }

    /// The user's name for it when there is one; otherwise "Square" for 1:1 and the two numbers
    /// for the others: "3:2", "2.39:1".
    public var name: String {
        label ?? (width == height ? "Square" : "\(Self.text(width)):\(Self.text(height))")
    }

    public func matches(_ value: Double) -> Bool {
        abs(self.value - value) < Self.tolerance
    }

    /// A name for a ratio known only by its value (a recipe locked to a ratio no longer listed).
    public static func name(forValue value: Double) -> String {
        "\(text(value)):1"
    }

    /// At most two decimals, none when they're zeros; a point whatever the locale, as in "2.39:1".
    private static func text(_ number: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), number)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}

/// The user's own crop ratios, listed in the crop tool after the built-in ones, in the order they
/// were added. One JSON file in the app's Application Support folder: user data, shared by every
/// photo. A recipe holds the ratio's value, never a reference to the list, so removing a ratio
/// changes no photo.
@Observable
public final class CropRatioStore {
    public private(set) var ratios: [CropRatio] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "CropRatioStore")

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Crop Ratios.json")
    }

    public init(fileURL: URL = CropRatioStore.defaultURL()) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            ratios = try JSONDecoder().decode([CropRatio].self, from: data)
        } catch {
            logger.error("Unreadable crop ratios: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The listed ratio, built-in or the user's, a crop locked to `value` is using.
    public func listed(matching value: Double) -> CropRatio? {
        (CropRatio.builtIn + ratios).first { $0.matches(value) }
    }

    /// Adds a ratio and returns the one to use: the ratio already listed with the same value when
    /// there is one (6:4 is 3:2), so the list never shows the same frame twice. Adding a named
    /// ratio over one of the user's own renames that one, in place; built-in ratios keep their name.
    @discardableResult
    public func add(_ ratio: CropRatio) throws -> CropRatio {
        if let existing = listed(matching: ratio.value) {
            guard ratio.label != nil, ratio.label != existing.label, let index = ratios.firstIndex(of: existing),
                  let renamed = CropRatio(width: existing.width, height: existing.height, label: ratio.label)
            else { return existing }
            var renamedRatios = ratios
            renamedRatios[index] = renamed
            try write(renamedRatios)
            logger.notice("Renamed crop ratio \(existing.name, privacy: .public) to \(renamed.name, privacy: .public)")
            return renamed
        }
        try write(ratios + [ratio])
        logger.notice("Added crop ratio \(ratio.name, privacy: .public)")
        return ratio
    }

    public func remove(_ ratio: CropRatio) throws {
        try write(ratios.filter { $0 != ratio })
        logger.notice("Removed crop ratio \(ratio.name, privacy: .public)")
    }

    /// The file first: the list only shows what was kept.
    private func write(_ newRatios: [CropRatio]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(newRatios).write(to: fileURL, options: .atomic)
        ratios = newRatios
    }
}
