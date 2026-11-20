import EditModel
import LibraryKit
import OSLog
import RenderEngine
import SwiftUI

@main
struct QaamaApp: App {
    @State private var catalog = Self.makeCatalog()
    /// What the Filter panel of each library shows, the same in every window.
    @State private var filterPanels = LibraryFilterPanels()

    /// The catalog gets the rendering engine through a closure, so LibraryKit stays independent of it.
    private static func makeCatalog() -> LibraryCatalog {
        let store: CatalogStore
        do {
            store = try CatalogStore(url: CatalogStore.defaultURL())
        } catch {
            // Without a catalog on disk the app still runs; folders just won't persist.
            Logger(subsystem: "fr.michaelperrin.qaama", category: "App").error("Catalog unavailable: \(error.localizedDescription, privacy: .public)")
            store = try! CatalogStore.inMemory()
        }
        // The DETR segmentation model ships in the bundle (Apache 2.0, see Resources/Models/README.md).
        ModelMasks.useSceneModel(at: Bundle.main.url(forResource: "DETRResnet50SemanticSegmentationF16", withExtension: "mlmodelc"))
        let catalog = LibraryCatalog(store: store, filterPresets: FilterPresetStore(fileURL: FilterPresetStore.defaultURL()),
                                     cameras: CameraDevices(browser: ImageCaptureBrowser(), history: ImportHistory(fileURL: ImportHistory.defaultURL())),
                                     importPresets: ImportPresetStore(fileURL: ImportPresetStore.defaultURL()))
        catalog.previewRenderer = { input, recipeData in
            let recipe = try EditRecipe(jsonData: recipeData)
            return try await EditRenderer.jpeg(imageURL: input.imageURL, image: input.image, recipe: recipe)
        }
        return catalog
    }

    var body: some Scene {
        WindowGroup("Qaama") {
            MainWindowView(catalog: catalog)
                .frame(minWidth: 900, minHeight: 550)
                .environment(filterPanels)
        }
        .windowStyle(.automatic)
        .commands { EditorCommands() }
        Settings {
            SettingsView()
        }
    }
}
