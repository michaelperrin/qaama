import EditModel
import Foundation
import LibraryKit
import OSLog
import RenderEngine

/// Copy and paste adjustments from the grid, without opening the editor: reads or writes the saved
/// recipe of a photo, rendering the full-size result the source needs.
public nonisolated enum BatchEditing {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "BatchEditing")

    /// Copies the saved adjustments of a photo (nothing happens if it has none).
    @MainActor
    public static func copyAdjustments(of asset: LibraryAsset, from source: any LibrarySource, to clipboard: AdjustmentsClipboard = .shared) async throws {
        let input = try await source.editingInput(for: asset)
        defer { source.endEditing(asset) }
        guard let data = input.recipeData, let recipe = try? EditRecipe(jsonData: data) else {
            throw BatchError.nothingToCopy
        }
        clipboard.copy(recipe.global)
    }

    /// Pastes the copied adjustments onto each photo, keeping each photo's crop, and saves. The change
    /// is registered with `undoManager` as one undoable step. Returns the number of photos updated;
    /// errors on individual photos are logged and skipped.
    @MainActor
    @discardableResult
    public static func pasteAdjustments(to assets: [LibraryAsset], in source: any LibrarySource, from clipboard: AdjustmentsClipboard = .shared,
                                        undoManager: UndoManager? = nil) async throws -> Int
    {
        guard let adjustments = clipboard.adjustments else { throw BatchError.clipboardEmpty }
        var targets: [(LibraryAsset, Data)] = []
        for asset in assets {
            let input = try await source.editingInput(for: asset)
            source.endEditing(asset)
            var recipe = input.recipeData.flatMap { try? EditRecipe(jsonData: $0) } ?? EditRecipe()
            recipe.global = adjustments
            try targets.append((asset, recipe.jsonData()))
        }
        return await write(targets, in: source, undoManager: undoManager, actionName: "Paste Adjustments")
    }

    /// Saves a recipe (nil = revert) per photo, after recording the previous recipes so the whole
    /// step can be undone; the undo registers the redo the same way.
    @MainActor
    @discardableResult
    static func write(_ recipes: [(LibraryAsset, Data?)], in source: any LibrarySource, undoManager: UndoManager?, actionName: String) async -> Int {
        var previous: [(LibraryAsset, Data?)] = []
        var updated = 0
        for (asset, recipeData) in recipes {
            do {
                let input = try await source.editingInput(for: asset)
                defer { source.endEditing(asset) }
                previous.append((asset, input.recipeData))
                let recipe = try recipeData.map { try EditRecipe(jsonData: $0) } ?? EditRecipe()
                let rendered = recipe.isIdentity ? Data() : try await Task.detached(priority: .userInitiated) {
                    try EditRenderer.jpeg(imageURL: input.imageURL, image: input.image, recipe: recipe)
                }.value
                try await source.saveEdit(EditingOutput(recipeData: recipe.jsonData(), renderedJPEG: rendered, isReset: recipe.isIdentity), for: asset)
                updated += 1
            } catch {
                logger.error("Writing adjustments failed for \(asset.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let undoManager, !previous.isEmpty {
            register(with: undoManager, restore: previous, redo: recipes, in: source, actionName: actionName)
        }
        return updated
    }

    /// Registers an undo that restores `restore`. Performed by the manager, it first registers its own
    /// inverse (the redo) synchronously, then writes; the source outlives the window's undo stack,
    /// which is what the target must do.
    @MainActor
    private static func register(with undoManager: UndoManager, restore: [(LibraryAsset, Data?)], redo: [(LibraryAsset, Data?)],
                                 in source: any LibrarySource, actionName: String)
    {
        undoManager.registerUndo(withTarget: source as AnyObject) { _ in
            MainActor.assumeIsolated {
                register(with: undoManager, restore: redo, redo: restore, in: source, actionName: actionName)
            }
            Task { @MainActor in
                await write(restore, in: source, undoManager: nil, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    public enum BatchError: Error, LocalizedError {
        case nothingToCopy
        case clipboardEmpty

        public var errorDescription: String? {
            switch self {
            case .nothingToCopy: "This photo has no adjustments to copy."
            case .clipboardEmpty: "Copy adjustments from a photo first."
            }
        }
    }
}
