import AppKit
import SwiftUI

/// The control of an inspector slider: a thin track, plain or painted with a gradient that shows
/// what each end does, and a small thumb.
///
/// Drawn by hand because the system slider fills its track with the accent color from the left
/// edge (a column of blue bars that says nothing for settings whose neutral point is the middle),
/// takes no gradient, and keeps the double-click for itself.
struct SliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// What the track shows from one end to the other; a plain gray track when nil.
    var gradient: Gradient?
    /// What a double-click brings the slider back to.
    var resetValue: Double = 0
    /// Called when a drag or a reset ends, so the owner can record one undo step per gesture.
    var onEditingEnded: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    static let thumbSize = CGSize(width: 8, height: 14)
    private static let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            // The thumb's center travels between the track's rounded ends.
            let travel = max(proxy.size.width - Self.thumbSize.width, 1)
            ZStack(alignment: .leading) {
                track
                thumb.offset(x: fraction * travel)
            }
            .frame(height: proxy.size.height)
            .overlay {
                SliderMouseArea(value: $value, range: range, resetValue: resetValue, isEnabled: isEnabled, onEditingEnded: onEditingEnded)
            }
        }
        .frame(height: Self.thumbSize.height)
    }

    private var track: some View {
        Group {
            // A slider that is off shows the plain track: its colors would promise an effect.
            if let gradient, isEnabled {
                Capsule().fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
            } else {
                Capsule().fill(.primary.opacity(0.14))
            }
        }
        .frame(height: Self.trackHeight)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var thumb: some View {
        Capsule()
            .fill(colorScheme == .dark ? Color(white: 0.78) : .white)
            .overlay(Capsule().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
            .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
            .opacity(isEnabled ? 1 : 0.6)
    }

    private var span: Double {
        range.upperBound - range.lowerBound
    }

    /// Position of the value along the track, 0 to 1.
    private var fraction: Double {
        span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
    }
}

/// The mouse handling of `SliderTrack`, in AppKit: next to a drag that starts on contact, SwiftUI's
/// double-tap gesture does not fire reliably, while a view is told the click count of each press.
private struct SliderMouseArea: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let resetValue: Double
    let isEnabled: Bool
    let onEditingEnded: () -> Void

    func makeNSView(context _: Context) -> SliderMouseView {
        SliderMouseView()
    }

    func updateNSView(_ view: SliderMouseView, context _: Context) {
        view.area = self
    }
}

/// Turns presses and drags into values: a press on the thumb drags it from where it is, so grabbing
/// it never changes the value; a press elsewhere on the track brings the thumb under the pointer
/// first; a double-click resets.
private final class SliderMouseView: NSView {
    var area: SliderMouseArea?
    /// Where the current drag was pressed, and the value the thumb had (or was brought to) then.
    private var drag: (pressX: CGFloat, origin: Double)?

    /// How far outside the thumb a press still grabs it rather than moving it.
    private static let grabMargin: CGFloat = 3

    /// The distance the thumb's center can cover.
    private var travel: CGFloat {
        max(bounds.width - SliderTrack.thumbSize.width, 1)
    }

    /// A drag on the track must never move the window.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        guard let area, area.isEnabled else { return }
        if event.clickCount >= 2 {
            drag = nil
            area.value = area.resetValue
            area.onEditingEnded()
            return
        }
        let range = area.range, span = range.upperBound - range.lowerBound
        let pressX = convert(event.locationInWindow, from: nil).x
        let halfThumb = SliderTrack.thumbSize.width / 2
        let current = min(max(area.value, range.lowerBound), range.upperBound)
        let thumbCenter = (span > 0 ? (current - range.lowerBound) / span : 0) * travel + halfThumb
        let isOnThumb = abs(pressX - thumbCenter) <= halfThumb + Self.grabMargin
        let origin = isOnThumb ? current : range.lowerBound + (pressX - halfThumb) / travel * span
        drag = (pressX, origin)
        move(to: origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let area, let drag else { return }
        let translation = convert(event.locationInWindow, from: nil).x - drag.pressX
        move(to: drag.origin + translation / travel * (area.range.upperBound - area.range.lowerBound))
    }

    override func mouseUp(with _: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        area?.onEditingEnded()
    }

    /// A drag reports many events per frame at the track's ends: only real changes are published.
    private func move(to value: Double) {
        guard let area else { return }
        let clamped = min(max(value, area.range.lowerBound), area.range.upperBound)
        if clamped != area.value {
            area.value = clamped
        }
    }
}
