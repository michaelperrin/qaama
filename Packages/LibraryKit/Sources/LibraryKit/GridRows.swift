import Foundation

/// What identifies a cell of the grid: its row in the listing and the section (month) it is laid
/// out in.
///
/// The row alone was the identifier at first, so that a cell stayed the same view when the sections
/// were cut differently around it. But when a section is inserted above (a newer month found while
/// a card is being read, a photo taken in a new month), its rows are rows another section held a
/// moment before, and SwiftUI's lazy grid then keeps the old cells on screen and never installs
/// the new ones: they showed the photos the rows used to hold, with no way to update (seen with a
/// probe, 2026-11-19: the rows were built with the new photos, neither `==` nor `body` of their
/// cells was ever called). With the section in the identifier, a row that changes section is a
/// new cell.
public nonisolated struct GridRowID: Hashable, Sendable {
    public let row: Int
    public let section: DateTimeline.Section.ID

    public init(row: Int, section: DateTimeline.Section.ID) {
        self.row = row
        self.section = section
    }
}

/// The rows of a section as the identifiers of their cells, computed on demand: a section can hold
/// tens of thousands of rows, and the grid only asks for those it shows.
public nonisolated struct GridSectionRows: RandomAccessCollection, Sendable {
    public let section: DateTimeline.Section

    public init(_ section: DateTimeline.Section) {
        self.section = section
    }

    public var startIndex: Int {
        section.range.lowerBound
    }

    public var endIndex: Int {
        section.range.upperBound
    }

    public subscript(position: Int) -> GridRowID {
        GridRowID(row: position, section: section.id)
    }
}

public extension DateTimeline {
    /// The identifier of the cell showing a row, to scroll the grid to it; nil past the end.
    nonisolated func rowID(_ row: Int) -> GridRowID? {
        section(containing: row).map { GridRowID(row: row, section: $0.id) }
    }
}
