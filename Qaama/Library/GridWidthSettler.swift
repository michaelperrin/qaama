import AppKit
import SwiftUI

/// Keeps the grid at the width it has while that width is being animated (a side column of the
/// window sliding in or out, the window zooming), and gives it its new width once, when the
/// animation has stopped.
///
/// A lazy grid of tens of thousands of photos in hundreds of months costs 60 to 110 ms to lay out
/// at a new width, in Release as in Debug: the time is SwiftUI's (measured with a probe, see
/// docs/PLAN.md). Laid out again at every frame of the sidebar's animation, it made the animation
/// stutter. Held, the grid stays still while the column moves, and makes its new rows once: at
/// the first frame when it gets wider (the column leaves, and uncovers a grid already in place),
/// at the end when it gets narrower (the column comes over a grid that still fills its place).
///
/// At rest the grid is pinned at the width it is offered, so the first frame of an animation
/// already leaves it alone: nothing announces that frame. What SwiftUI tells of a column's
/// visibility can't: measured with a probe, View › Hide Sidebar only changes the binding once the
/// animation is over.
///
/// A window resized by hand isn't waited out: the grid is let go for the time of the resize, and
/// follows as before. The edge of the sidebar dragged by hand is waited out like an animation.
@Observable
final class GridWidthSettler {
    /// The width the grid is pinned at; nil lets it take the width it is offered (the first
    /// layouts of a view, which the window makes at provisional sizes, and a resize by hand).
    private(set) var pinned: CGFloat?
    /// True when it is the leading edge that moves (the sidebar): the grid then keeps its trailing
    /// edge where it is, so it stays still on screen.
    private(set) var keepsTrailingEdge = false
    /// The width last offered to the grid.
    @ObservationIgnored private var offered: CGFloat = 0
    /// Until when the offered width is waited on; nil when it is the one the grid has.
    @ObservationIgnored private var quietUntil: ContinuousClock.Instant?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var isResizedByHand = false
    /// The width of the column on the trailing side when it is shown (the inspector); 0 without one.
    @ObservationIgnored var trailingColumnWidth: CGFloat = 0

    /// How long the width must have stayed the same to be taken as the one to lay the grid out at.
    private static let quietTime: Duration = .milliseconds(100)

    /// Tells where the grid's place in the window is now, as it changes.
    func placeChanged(from old: CGRect, to new: CGRect) {
        offered = new.width
        guard !isResizedByHand, new.width != pinned else { return }
        if let pinned {
            let leadingEdgeMoved = new.minX != old.minX
            if leadingEdgeMoved, !keepsTrailingEdge {
                keepsTrailingEdge = true
            }
            // The first frame of a column sliding away: the grid takes at once the width it will
            // have, under the column, which then uncovers photos already in place. Waiting for the
            // column to be gone left a blank band where it was, filled all at once (Michaël,
            // 2026-11-17). Not while a button is down: an edge dragged by hand may stop anywhere.
            if quietUntil == nil, new.width > pinned, NSEvent.pressedMouseButtons == 0 {
                // The sidebar leaves the room it took from the window's edge; the inspector, its width.
                let room = leadingEdgeMoved ? old.minX : trailingColumnWidth
                if room > 0 {
                    self.pinned = pinned + room
                }
            }
        }
        quietUntil = .now + Self.quietTime
        guard waiting == nil else { return }
        waiting = Task { [weak self] in
            while let until = self?.quietUntil, ContinuousClock.now < until {
                try? await Task.sleep(until: until)
            }
            self?.settle()
        }
    }

    /// The window is being resized by hand, or no longer is.
    func resizeByHand(_ isResizing: Bool) {
        isResizedByHand = isResizing
        if isResizing {
            quietUntil = nil
            pinned = nil
            keepsTrailingEdge = false
        } else {
            settle()
        }
    }

    private func settle() {
        waiting = nil
        quietUntil = nil
        guard !isResizedByHand, offered > 0 else { return }
        keepsTrailingEdge = false
        pinned = offered
    }
}

/// Lays its content out at the width the settler holds, against the edge that isn't moving.
///
/// With frames only: inside a container of our own (a `Layout`, a `GeometryReader`) the scroll view
/// loses the toolbar's soft edge, and photos show sharp under the window's title (seen with a probe).
struct SettledWidth<Content: View>: View {
    /// The width of the inspector next to the content, which it leaves to the content when hidden.
    var trailingColumnWidth: CGFloat = 0
    @ViewBuilder let content: Content
    @State private var settler = GridWidthSettler()

    var body: some View {
        let edge: Alignment = settler.keepsTrailingEdge ? .trailing : .leading
        content
            .frame(width: settler.pinned)
            // The pinned grid counts for nothing in the width of what follows: a frame with a maximum
            // alone grows to hold a wider grid, and a width getting smaller would go unseen.
            .frame(width: settler.pinned == nil ? nil : 0, alignment: edge)
            .frame(maxWidth: .infinity, alignment: edge)
            // Known after the layout: the first frame of a hold may still keep the other edge.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { old, new in settler.placeChanged(from: old, to: new) }
            .onChange(of: trailingColumnWidth, initial: true) { settler.trailingColumnWidth = trailingColumnWidth }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { _ in settler.resizeByHand(true) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in settler.resizeByHand(false) }
    }
}
