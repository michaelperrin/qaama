import LibraryKit
import SwiftUI

@main
struct QaamaApp: App {
    @State private var catalog = LibraryCatalog()

    var body: some Scene {
        WindowGroup("Qaama") {
            MainWindowView(catalog: catalog)
                .frame(minWidth: 900, minHeight: 550)
        }
        .windowStyle(.automatic)
    }
}
