import EditModel
import LibraryKit
import RenderEngine
import SwiftUI

@main
struct QaamaApp: App {
    @State private var catalog = Self.makeCatalog()

    /// The catalog gets the rendering engine through a closure, so LibraryKit stays independent of it.
    private static func makeCatalog() -> LibraryCatalog {
        let catalog = LibraryCatalog()
        catalog.previewRenderer = { input, recipeData in
            let recipe = try EditRecipe(jsonData: recipeData)
            return try EditRenderer.jpeg(imageURL: input.imageURL, image: input.image, recipe: recipe)
        }
        return catalog
    }

    var body: some Scene {
        WindowGroup("Qaama") {
            MainWindowView(catalog: catalog)
                .frame(minWidth: 900, minHeight: 550)
        }
        .windowStyle(.automatic)
    }
}
