import AppKit
import OSLog
import SwiftUI

/// Shows files in the Finder, selected in their folder: the photos of a folder library, from the
/// grid's context menu and the inspector's File line. The Finder does the work, so the sandbox
/// needs nothing beyond the access the folder already has.
enum FinderReveal {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FinderReveal")

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        logger.notice("Showed \(urls.count) files in the Finder")
    }
}

/// The ellipsis button of the inspector's File line, with what can be done with the file.
struct FileActionsMenu: View {
    let showInFinder: () -> Void

    var body: some View {
        Menu {
            Button("Show in Finder", action: showInFinder)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("File actions")
        .accessibilityLabel("File actions")
    }
}
