import Foundation
import ImageIOKit
import LibraryKit

/// The lines of the Info panel, ready to show, for one photo or for several: with several, a line
/// holds the value they all share, or says that they differ.
public nonisolated struct InfoSummary: Hashable, Sendable {
    public enum Row: Hashable, Sendable {
        /// No photo says anything: the line is left out.
        case none
        /// What the photo says, or what all the photos say alike.
        case value(String)
        /// The photos say different things, or only some of them say something.
        case mixed
    }

    public var camera = Row.none
    public var lens = Row.none
    public var exposure = Row.none
    public var size = Row.none
    /// One date, or the span of the dates when the photos were taken at different times.
    public var captured = Row.none
    /// Photos left out of the camera, lens and exposure lines because their header couldn't be read:
    /// their original is in iCloud. Their size and date, which the library knows, still count.
    public var unreadCount = 0

    /// True when there is nothing to show.
    public var isEmpty: Bool {
        [camera, lens, exposure, size, captured].allSatisfy { $0 == .none }
    }

    public init() {}

    public init(_ details: [AssetDetails], calendar: Calendar = .current) {
        let known = details.compactMap(\.metadata)
        // Camera settings come from the header only: a photo whose original is away is unknown, not different.
        let read = details.filter { !$0.isOriginalInCloud }.compactMap(\.metadata)
        unreadCount = details.count(where: \.isOriginalInCloud)
        camera = Self.row(read.map(Self.camera))
        lens = Self.row(read.map(\.lens))
        exposure = Self.row(read.map(Self.exposure))
        size = Self.row(known.map { $0.pixelWidth > 0 && $0.pixelHeight > 0 ? "\($0.pixelWidth) × \($0.pixelHeight)" : nil })
        captured = Self.captured(known.compactMap(\.captureDate), calendar: calendar)
    }

    /// The summary of one header, for a place that has no `AssetDetails` (the editor).
    public init(metadata: ImageMetadata?) {
        self.init(metadata.map { [AssetDetails(metadata: $0)] } ?? [])
    }

    /// One value when every photo has it and they agree, nothing when none has it, mixed otherwise.
    static func row(_ values: [String?]) -> Row {
        let present = values.compactMap(\.self)
        guard let first = present.first else { return .none }
        return present.count == values.count && present.allSatisfy { $0 == first } ? .value(first) : .mixed
    }

    static func camera(_ metadata: ImageMetadata) -> String? {
        let parts = [metadata.cameraMake, metadata.cameraModel].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "1/250 s · f/2.8 · ISO 800 · 35 mm", skipping what the file doesn't say.
    static func exposure(_ metadata: ImageMetadata) -> String? {
        var parts: [String] = []
        if let time = metadata.exposureTime {
            parts.append(time >= 1 ? "\(time.formatted(.number.precision(.fractionLength(0 ... 1)))) s" : "1/\(Int((1 / time).rounded())) s")
        }
        if let aperture = metadata.aperture {
            parts.append("f/\(aperture.formatted(.number.precision(.fractionLength(0 ... 1))))")
        }
        if let iso = metadata.iso {
            parts.append("ISO \(iso)")
        }
        if let focal = metadata.focalLength {
            parts.append("\(focal.formatted(.number.precision(.fractionLength(0)))) mm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A single date with its time; several on one day as that day with the span of times; across
    /// days as the span of days, without times, which no longer say much. Each end is spelled like a
    /// single date: the system's interval style orders day and month its own way.
    static func captured(_ dates: [Date], calendar: Calendar = .current) -> Row {
        guard let earliest = dates.min(), let latest = dates.max() else { return .none }
        if earliest == latest {
            return .value(earliest.formatted(date: .abbreviated, time: .shortened))
        }
        if calendar.isDate(earliest, inSameDayAs: latest) {
            let day = earliest.formatted(date: .abbreviated, time: .omitted)
            return .value("\(day), \(earliest.formatted(date: .omitted, time: .shortened)) – \(latest.formatted(date: .omitted, time: .shortened))")
        }
        return .value("\(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))")
    }
}
