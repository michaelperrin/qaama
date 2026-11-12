import EditModel
import SwiftUI

/// The gradients painted on the tracks of the color sliders: each shows what its slider does to
/// the photo from one end to the other. Sliders of light and detail keep a plain track.
enum SliderGradients {
    private static let neutral = Color(white: 0.6)

    /// Cooler to warmer.
    static let temperature = Gradient(colors: [Color(red: 0.22, green: 0.55, blue: 1), neutral, Color(red: 1, green: 0.76, blue: 0.2)])
    /// Green to magenta.
    static let tint = Gradient(colors: [Color(red: 0.3, green: 0.8, blue: 0.3), neutral, Color(red: 0.93, green: 0.3, blue: 0.75)])
    /// Gray to a muted color: vibrance spares what is already saturated.
    static let vibrance = Gradient(colors: [neutral, Color(hue: 0.03, saturation: 0.6, brightness: 0.92)])
    /// Gray to vivid.
    static let saturation = Gradient(colors: [neutral, Color(hue: 0, saturation: 0.9, brightness: 0.95)])

    /// The hues a color range of the mixer can be turned to, `HSL.hueSpan` degrees each way.
    static func hue(of range: HSL.ColorRange) -> Gradient {
        Gradient(colors: [-1.0, -0.5, 0, 0.5, 1].map { color(hue: range.hue + $0 * HSL.hueSpan) })
    }

    /// A color range from gray to fully saturated.
    static func saturation(of range: HSL.ColorRange) -> Gradient {
        Gradient(colors: [neutral, color(hue: range.hue, saturation: 0.9)])
    }

    /// A color range from dark to light.
    static func luminance(of range: HSL.ColorRange) -> Gradient {
        tone(hue: range.hue)
    }

    /// One channel of the black and white mix, from the grays it darkens to the ones it lightens.
    static func tone(hue: Double) -> Gradient {
        Gradient(colors: [color(hue: hue, saturation: 0.85, brightness: 0.35), color(hue: hue, saturation: 0.45, brightness: 1)])
    }

    /// A display color for a hue in degrees, of any sign.
    static func color(hue: Double, saturation: Double = 0.75, brightness: Double = 0.9) -> Color {
        let turns = (hue / 360).truncatingRemainder(dividingBy: 1)
        return Color(hue: turns < 0 ? turns + 1 : turns, saturation: saturation, brightness: brightness)
    }
}
