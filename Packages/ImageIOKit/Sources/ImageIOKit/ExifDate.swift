import Foundation

/// How EXIF spells dates: a local wall-clock time ("2026:10:29 14:03:12") and, since EXIF 2.31, an
/// optional offset from UTC ("+01:00") that pins it to an instant. Reading and writing go through
/// here so one is the exact inverse of the other.
public nonisolated enum ExifDate {
    /// The instant a wall-clock time stands for: in the zone of its offset when it has one, in
    /// `fallback` otherwise. Nil when the text isn't an EXIF date.
    public static func date(from text: String, offset: String?, fallback: TimeZone = .current) -> Date? {
        formatter(in: offset.flatMap(timeZone(fromOffset:)) ?? fallback).date(from: text)
    }

    /// The wall-clock spelling of an instant in a time zone.
    public static func string(from date: Date, in timeZone: TimeZone) -> String {
        formatter(in: timeZone).string(from: date)
    }

    /// "+01:00", "-03:30": how far a time zone is from UTC at that instant (daylight saving included).
    public static func offsetString(of timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }

    /// The fixed zone an offset such as "+01:00" stands for; nil when it isn't one.
    public static func timeZone(fromOffset offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":")
        guard offset.count == 6, offset.hasPrefix("+") || offset.hasPrefix("-"), parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let sign = offset.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    private static func formatter(in timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter
    }
}
