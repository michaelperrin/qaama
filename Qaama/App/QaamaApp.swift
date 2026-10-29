import LibraryKit
import SwiftUI

@main
struct QaamaApp: App {
    @State private var photosSource = PhotosLibrarySource()

    var body: some Scene {
        WindowGroup("Qaama") {
            LibraryView(source: photosSource)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.automatic)
    }
}
