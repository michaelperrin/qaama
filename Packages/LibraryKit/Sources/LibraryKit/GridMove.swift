import Foundation

/// A move of the selection through a grid by the arrow keys.
public nonisolated enum GridMove: Sendable {
    case left, right, up, down
}

public nonisolated extension DateTimeline {
    /// The row an arrow key moves to from `index`, in a grid that lays each section out in rows of
    /// `columns` cells and starts every section on a row of its own; nil when there is nowhere to go.
    ///
    /// Left and right step through the listing, from one section into the next as in Photos. Up and
    /// down keep the column: into the next section's first row, or the previous one's last, as far
    /// as that row reaches; into the short last row of a section, onto its last photo, as the Finder
    /// does.
    func row(from index: Int, moving move: GridMove, columns: Int) -> Int? {
        guard let section = section(containing: index) else { return nil }
        let columns = max(columns, 1)
        let column = (index - section.range.lowerBound) % columns
        let rowStart = index - column
        switch move {
        case .left:
            return index > 0 ? index - 1 : nil
        case .right:
            return index + 1 < count ? index + 1 : nil
        case .down:
            if rowStart + columns < section.range.upperBound {
                return min(index + columns, section.range.upperBound - 1)
            }
            guard let next = self.section(containing: section.range.upperBound) else { return nil }
            return next.range.lowerBound + min(column, next.range.count - 1)
        case .up:
            if rowStart > section.range.lowerBound {
                return index - columns
            }
            guard section.range.lowerBound > 0, let previous = self.section(containing: section.range.lowerBound - 1) else { return nil }
            let lastRowStart = previous.range.lowerBound + (previous.range.count - 1) / columns * columns
            return min(lastRowStart + column, previous.range.upperBound - 1)
        }
    }
}
