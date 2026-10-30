import RenderEngine
import SwiftUI

/// Three translucent channel histograms drawn as bars with Canvas; cheap enough to redraw on every change.
struct HistogramView: View {
    let histogram: Histogram?
    /// Width of the clipping indicators at both edges, in points.
    private static let wallWidth: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            let channels = [(histogram.red, Color.red), (histogram.green, Color.green), (histogram.blue, Color.blue)]
            for (channel, color) in channels {
                context.fill(path(for: channel, in: size), with: .color(color.opacity(0.45)))
            }
            // Clipped shadows and highlights: the first and last bins, drawn as wide opaque walls so a
            // blown-out channel reads at a glance instead of hiding in a one-pixel column.
            for (channel, color) in channels {
                if let first = channel.first, first > 0 {
                    context.fill(Path(CGRect(x: 0, y: size.height * (1 - CGFloat(first)), width: Self.wallWidth, height: size.height * CGFloat(first))), with: .color(color.opacity(0.9)))
                }
                if let last = channel.last, last > 0 {
                    context.fill(Path(CGRect(x: size.width - Self.wallWidth, y: size.height * (1 - CGFloat(last)), width: Self.wallWidth, height: size.height * CGFloat(last))), with: .color(color.opacity(0.9)))
                }
            }
        }
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
        .frame(height: 90)
        .overlay {
            if histogram == nil {
                Text("No histogram").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Histogram")
    }

    /// One bar per bin, so a single clipped bin at either edge still shows as a wall.
    private func path(for bins: [Float], in size: CGSize) -> Path {
        var path = Path()
        guard !bins.isEmpty else { return path }
        let step = size.width / CGFloat(bins.count)
        for (index, value) in bins.enumerated() where value > 0 {
            let height = max(1, size.height * CGFloat(value))
            path.addRect(CGRect(x: CGFloat(index) * step, y: size.height - height, width: step, height: height))
        }
        return path
    }
}

#Preview {
    HistogramView(histogram: Histogram(
        red: (0 ..< 256).map { Float(exp(-pow(Double($0 - 100) / 40, 2))) },
        green: (0 ..< 256).map { Float(exp(-pow(Double($0 - 128) / 50, 2))) },
        blue: (0 ..< 256).map { Float(exp(-pow(Double($0 - 160) / 30, 2))) }
    ))
    .padding()
    .frame(width: 260)
}
