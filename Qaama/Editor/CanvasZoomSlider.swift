import RenderEngine
import SwiftUI

/// The editor's zoom slider, in the toolbar where the grid has its thumbnail size slider: logarithmic
/// over the canvas's zoom range, which starts at Fit (the whole photo in the view), with a detent at
/// 100% (one pixel of the photo per pixel of the screen), marked under the track, and the zoom as a
/// percentage of the photo's real size next to it. For a photo smaller than the view the range
/// starts at 100% instead and the detent is Fit.
struct CanvasZoomSlider: View {
    let renderer: CanvasRenderer

    /// Half-width of a detent, in doublings: the knob snaps within about 7% of the value.
    private static let detentHalfWidth: Double = 0.1
    /// Half the knob's width, where the track starts and ends inside the slider's frame.
    private static let knobInset: CGFloat = 8

    var body: some View {
        let range = range
        let detents = detents(in: range)
        HStack(spacing: 8) {
            Slider(value: Binding(get: { log2(Double(renderer.zoom)) }, set: { renderer.setZoom(CGFloat(pow(2, snapped($0, to: detents)))) }),
                   in: range)
            {
                Text("Zoom")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140)
            .overlay(alignment: .bottom) {
                DetentMarks(positions: detents.map { ($0 - range.lowerBound) / (range.upperBound - range.lowerBound) }, inset: Self.knobInset)
                    .frame(height: 3)
                    .offset(y: 2)
                    .allowsHitTesting(false)
            }
            if let percent {
                Text(percent, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .help(range.lowerBound < 0 ? "Zoom, from 100%; the mark is Fit" : "Zoom, from Fit; the mark is 100%")
    }

    /// The canvas's zoom range, in doublings; 0 is Fit.
    private var range: ClosedRange<Double> {
        let zoomRange = renderer.zoomRange
        return log2(Double(zoomRange.lowerBound)) ... log2(Double(zoomRange.upperBound))
    }

    /// Fit and 100%, in doublings, when they are inside the range: the one the range starts at
    /// needs no detent, the slider stops there by itself.
    private func detents(in range: ClosedRange<Double>) -> [Double] {
        var values = [0.0]
        if let actual = renderer.actualSizeZoom {
            values.append(log2(Double(actual)))
        }
        return values.filter { $0 > range.lowerBound + Self.detentHalfWidth && $0 <= range.upperBound }
    }

    /// The zoom as a fraction of the photo's real size, nil until the canvas knows its size.
    private var percent: Double? {
        renderer.actualSizeZoom.map { Double(renderer.zoom / $0) }
    }

    private func snapped(_ value: Double, to detents: [Double]) -> Double {
        detents.first { abs($0 - value) < Self.detentHalfWidth } ?? value
    }
}

/// Short ticks under a slider's track, at fractions of its length.
private struct DetentMarks: View {
    let positions: [Double]
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            for position in positions {
                let x = inset + CGFloat(position) * (size.width - 2 * inset)
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .style(.tertiary))
            }
        }
    }
}
