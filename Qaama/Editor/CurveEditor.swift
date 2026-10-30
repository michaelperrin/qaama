import EditModel
import SwiftUI

/// Tone curve editor: drag points, click the curve to add one, double-click a point to remove it.
/// Works on the channel chosen above it; the RGB curve is drawn as a ghost behind the others.
struct CurveEditor: View {
    @Binding var curves: Curves
    let onEditingEnded: () -> Void

    @State private var channel = Curves.Channel.rgb
    @State private var draggedIndex: Int?

    private static let editorHeight: CGFloat = 220
    private static let pointRadius: CGFloat = 5
    private static let hitRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: 8) {
            Picker("Channel", selection: $channel) {
                Text("RGB").tag(Curves.Channel.rgb)
                Text("Red").tag(Curves.Channel.red)
                Text("Green").tag(Curves.Channel.green)
                Text("Blue").tag(Curves.Channel.blue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            // Segmented controls ask for their labels' natural width; let the column win.
            .frame(maxWidth: .infinity)
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Canvas { context, size in
                        drawGrid(context, size)
                        if channel != .rgb {
                            context.stroke(path(for: curves.rgb, in: size), with: .color(.white.opacity(0.25)), lineWidth: 1)
                        }
                        context.stroke(path(for: curves[channel], in: size), with: .color(channelColor), lineWidth: 1.5)
                        for (index, point) in curves[channel].points.enumerated() {
                            let center = viewPoint(point, in: size)
                            let rect = CGRect(x: center.x - Self.pointRadius, y: center.y - Self.pointRadius,
                                              width: Self.pointRadius * 2, height: Self.pointRadius * 2)
                            context.fill(Path(ellipseIn: rect), with: .color(index == draggedIndex ? channelColor : .white))
                            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.6)), lineWidth: 1)
                        }
                    }
                    .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(drag(in: size))
                    .onTapGesture(count: 2) { location in
                        if let index = hitIndex(at: location, in: size) {
                            curves[channel].remove(at: index)
                            onEditingEnded()
                        }
                    }
                }
            }
            .frame(height: Self.editorHeight)
            HStack {
                Spacer()
                Button("Reset Curve") {
                    curves[channel] = .identity
                    onEditingEnded()
                }
                .disabled(curves[channel].isIdentity)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Interaction

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggedIndex == nil {
                    if let index = hitIndex(at: value.startLocation, in: size) {
                        draggedIndex = index
                    } else {
                        // Clicking away from a point adds one on the curve at that x.
                        let start = curvePoint(value.startLocation, in: size)
                        draggedIndex = curves[channel].insert(CurvePoint(x: start.x, y: curves[channel].evaluate(start.x)))
                    }
                }
                guard let draggedIndex else { return }
                curves[channel].move(draggedIndex, to: curvePoint(value.location, in: size))
            }
            .onEnded { _ in
                draggedIndex = nil
                onEditingEnded()
            }
    }

    private func hitIndex(at location: CGPoint, in size: CGSize) -> Int? {
        curves[channel].points.indices.min { lhs, rhs in
            distance(location, viewPoint(curves[channel].points[lhs], in: size)) < distance(location, viewPoint(curves[channel].points[rhs], in: size))
        }.flatMap { index in
            distance(location, viewPoint(curves[channel].points[index], in: size)) <= Self.hitRadius ? index : nil
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Drawing

    private var channelColor: Color {
        switch channel {
        case .rgb: .white
        case .red: .red
        case .green: .green
        case .blue: Color(red: 0.4, green: 0.6, blue: 1)
        }
    }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for quarter in 1 ... 3 {
            let x = size.width * CGFloat(quarter) / 4, y = size.height * CGFloat(quarter) / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    }

    private func path(for curve: ToneCurve, in size: CGSize) -> Path {
        var path = Path()
        let samples = curve.samples(count: 128)
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(samples.count - 1), y: size.height * (1 - CGFloat(value)))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func viewPoint(_ point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * point.x, y: size.height * (1 - point.y))
    }

    private func curvePoint(_ location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(x: location.x / size.width, y: 1 - location.y / size.height)
    }
}

#Preview {
    @Previewable @State var curves: Curves = {
        var curves = Curves()
        curves.rgb.insert(CurvePoint(x: 0.3, y: 0.2))
        curves.rgb.insert(CurvePoint(x: 0.7, y: 0.8))
        return curves
    }()
    CurveEditor(curves: $curves) {}
        .padding()
        .frame(width: 260)
}
