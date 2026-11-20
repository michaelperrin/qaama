import AppKit
import LibraryKit
import SwiftUI

/// The rubber band of the grid: a drag that starts where there is no photo (between thumbnails,
/// beside a photo shown whole in its square, below the last row) draws a rectangle and selects
/// every thumbnail it touches, as in the Finder and Photos. Where a photo can't be dragged
/// anywhere (a device, a folder), a drag from a photo draws it too. Without a modifier it replaces the
/// selection, with ⇧ it adds to it, with ⌘ it toggles what it touches. A click there without
/// dragging clears the selection.
///
/// The gesture is on the whole content, alongside the cells' own, and tells for itself whether a
/// press is on a photo, from the frames of the photos: a gesture behind the cells, reached only
/// where none took the press, never got the presses between some columns (Michaël, 2026-11-20).
///
/// Everything is in the coordinates of the grid's content (`space`), which don't move as it
/// scrolls: the cells report their frames there once laid out, and the rectangle keeps its origin
/// while the grid scrolls under it. Dragging past the top or the bottom of the visible area
/// scrolls, faster the farther the pointer is, and the rectangle follows.
///
/// Only `rect` is observed, by the view that draws it: the grid itself reads nothing that changes
/// on every move of the pointer, and is updated only when the selection changes.
@MainActor
@Observable
final class GridMarquee {
    /// The coordinate space of the grid's content.
    nonisolated static let space = "GridContent"
    /// A drag shorter than this is a click.
    nonisolated static let threshold: CGFloat = 3
    private static let autoscrollInterval: Duration = .milliseconds(16)

    /// What a drag does to the selection it started from.
    enum Mode {
        case replace, add, toggle

        init(_ modifiers: NSEvent.ModifierFlags) {
            self = modifiers.contains(.command) ? .toggle : modifiers.contains(.shift) ? .add : .replace
        }
    }

    /// The rectangle drawn, in the content's coordinates; nil when no drag is under way.
    private(set) var rect: CGRect?

    /// A drag from a photo draws the rectangle too: set where photos can't be dragged anywhere.
    @ObservationIgnored var startsOnPhotos = false
    /// Frames of the photos laid out (the photo drawn, not the square of its cell), by row. Cells that leave the screen during a drag are kept:
    /// the rectangle can still cover them once the grid has scrolled them away.
    @ObservationIgnored private var frames: [Int: CGRect] = [:]
    @ObservationIgnored private var departed: Set<Int> = []
    @ObservationIgnored private var drag: (origin: CGPoint, pointer: CGPoint, mode: Mode, base: Set<LibraryAsset.ID>, isBand: Bool)?
    /// The press under way is on a photo that handles it (a click, a drag to an album): ignored.
    @ObservationIgnored private var isLeftToPhoto = false
    /// The part of the content shown between the toolbar and the bottom of the window, and the
    /// content's height: where autoscroll starts and stops.
    @ObservationIgnored private var visible = CGRect.zero
    @ObservationIgnored private var contentHeight: CGFloat = 0
    @ObservationIgnored private var autoscroll: Task<Void, Never>?

    /// Set by the grid at each update: the photo of a row, if the listing still has that row.
    @ObservationIgnored var assetID: (Int) -> LibraryAsset.ID? = { _ in nil }
    /// Scrolls so that this content coordinate is at the top of the visible area (`scrollTo(y:)`).
    @ObservationIgnored var scroll: (CGFloat) -> Void = { _ in }
    /// Called with the selection the rectangle makes, the first and the last row it covers, when it changes.
    @ObservationIgnored var select: (Set<LibraryAsset.ID>, ClosedRange<Int>?) -> Void = { _, _ in }

    func cellDidLayout(_ index: Int, frame: CGRect) {
        frames[index] = frame
        departed.remove(index)
    }

    func cellDidDisappear(_ index: Int) {
        if drag == nil {
            frames[index] = nil
        } else {
            departed.insert(index)
        }
    }

    /// Takes the scroll view's geometry. `scrollTo(y:)` puts a coordinate under the toolbar, at
    /// `visibleRect.minY + contentInsets.top` (measured, see docs/PLAN.md).
    func update(_ geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        visible = CGRect(x: geometry.visibleRect.minX, y: geometry.visibleRect.minY + insets.top,
                         width: geometry.visibleRect.width, height: max(geometry.visibleRect.height - insets.top - insets.bottom, 0))
        contentHeight = geometry.contentSize.height
    }

    /// The pointer moved, in the content's coordinates; `selection` is the grid's at the start.
    func dragChanged(start: CGPoint, location: CGPoint, selection: Set<LibraryAsset.ID>) {
        guard !isLeftToPhoto else { return }
        if drag == nil {
            let onPhoto = frames.values.contains { $0.contains(start) }
            if onPhoto, !startsOnPhotos {
                isLeftToPhoto = true
                return
            }
            let mode = Mode(NSEvent.modifierFlags)
            drag = (start, location, mode, mode == .replace ? [] : selection, false)
        }
        drag?.pointer = location
        guard let current = drag else { return }
        if !current.isBand {
            guard hypot(location.x - current.origin.x, location.y - current.origin.y) >= Self.threshold else { return }
            drag?.isBand = true
        }
        refresh()
        updateAutoscroll()
    }

    /// The button was released. Returns true for a click beside the photos.
    func dragEnded() -> Bool {
        let wasClick = drag.map { drag in !drag.isBand && !frames.values.contains { $0.contains(drag.origin) } } ?? false
        isLeftToPhoto = false
        drag = nil
        rect = nil
        autoscroll?.cancel()
        autoscroll = nil
        for index in departed {
            frames[index] = nil
        }
        departed.removeAll()
        return wasClick
    }

    /// Draws the rectangle from the drag's origin to the pointer and tells the selection it makes.
    private func refresh() {
        guard let drag else { return }
        let band = CGRect(x: min(drag.origin.x, drag.pointer.x), y: min(drag.origin.y, drag.pointer.y),
                          width: abs(drag.pointer.x - drag.origin.x), height: abs(drag.pointer.y - drag.origin.y))
        rect = band
        var covered = Set<LibraryAsset.ID>()
        var first = Int.max
        var last = Int.min
        for (index, frame) in frames where frame.intersects(band) {
            guard let id = assetID(index) else { continue }
            covered.insert(id)
            first = min(first, index)
            last = max(last, index)
        }
        let selection = switch drag.mode {
        case .replace: covered
        case .add: drag.base.union(covered)
        case .toggle: drag.base.symmetricDifference(covered)
        }
        select(selection, first <= last ? first ... last : nil)
    }

    /// How far to scroll at each step: the distance of the pointer past the edge of the visible
    /// area, a quarter of it per step, up to a row or so.
    private var autoscrollStep: CGFloat {
        guard let pointer = drag?.pointer, visible.height > 0 else { return 0 }
        let past = pointer.y < visible.minY ? pointer.y - visible.minY : pointer.y > visible.maxY ? pointer.y - visible.maxY : 0
        return past.magnitude < 1 ? 0 : (past / 4).clamped(to: -60 ... 60)
    }

    private func updateAutoscroll() {
        guard autoscrollStep != 0, autoscroll == nil else { return }
        autoscroll = Task { [weak self] in
            while !Task.isCancelled, let self, self.step() {
                try? await Task.sleep(for: Self.autoscrollInterval)
            }
            self?.autoscroll = nil
        }
    }

    /// Scrolls by one step; false once there is nothing left to scroll that way.
    private func step() -> Bool {
        let delta = autoscrollStep
        let top = (visible.minY + delta).clamped(to: 0 ... max(contentHeight - visible.height, 0))
        let moved = top - visible.minY
        guard moved != 0 else { return false }
        scroll(top)
        // The geometry is reported a frame later: until then, where it was asked to be.
        visible.origin.y = top
        // The pointer stays where it is on screen, so it moves through the content.
        drag?.pointer.y += moved
        refresh()
        return true
    }
}

/// The rectangle of `GridMarquee`, drawn over the grid's content: a light wash of the accent,
/// outlined, as the system draws one.
struct GridMarqueeRectangle: View {
    let marquee: GridMarquee

    var body: some View {
        if let rect = marquee.rect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
