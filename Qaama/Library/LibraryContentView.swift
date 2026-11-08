import EditorKit
import LibraryKit
import SwiftUI

/// Detail column of a library: the thumbnail grid, replaced by the editor while a photo is open.
/// Both keep the window's inspector column on their right: the selected photo's Info panel next to
/// the grid, the editor's tabs next to the canvas.
struct LibraryContentView: View {
    let source: any LibrarySource
    /// The albums the photos can be filed in; nil for libraries without albums (folders).
    var albums: AlbumFiling?
    /// The stay in the editor, from opening a photo to closing; it moves from photo to photo by itself.
    @State private var editorSession: EditorSession?
    @State private var selection: Set<LibraryAsset.ID> = []
    /// One setting for the grid and the editor, so the column stays put when a photo is opened.
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true
    /// The Adjust Date & Time dialog, opened from the Image menu, the grid's context menu or the Info panel.
    @State private var dateEdit: CaptureDateEditModel?
    /// What went wrong with a rating or a flag set from the Image menu, or with an album change.
    @State private var decisionError: String?
    /// The name being asked for a new album made from photos.
    @State private var albumDialog: AlbumDialog?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        content
            // View › Show Inspector acts on this window, grid or editor.
            .focusedSceneValue(\.hasInspector, true)
            .focusedSceneValue(\.adjustDateAction, adjustDateAction)
            .focusedSceneValue(\.decisionsAction, decisionsAction)
            .focusedSceneValue(\.albumsCommand, albumsCommand)
            .albumDialogs($albumDialog, editor: albums?.editor, error: $decisionError)
            .alert("Couldn't Update the Photos", isPresented: Binding(get: { decisionError != nil }, set: {
                if !$0 {
                    decisionError = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(decisionError ?? "")
            }
            // Above both the grid and the editor: the Image menu opens it from either.
            .sheet(item: $dateEdit) { model in
                CaptureDateEditView(model: model, undoManager: undoManager) { dateEdit = nil }
            }
    }

    /// Image › Adjust Date & Time…: the photo open in the editor, else the grid's selection; nil
    /// (the command is disabled) when there is neither, or the source can't store a corrected date.
    /// The photos are looked up when the command runs, not on every update of the view.
    private var adjustDateAction: AdjustDateAction? {
        guard source.capabilities.contains(.captureDate) else { return nil }
        if let editorSession {
            return AdjustDateAction { adjustDate(of: [editorSession.model.asset].compactMap(\.self)) }
        }
        guard !selection.isEmpty else { return nil }
        return AdjustDateAction { adjustDate(of: selection.compactMap { source.asset(id: $0) }) }
    }

    @ViewBuilder
    private var content: some View {
        if let editorSession {
            EditorView(session: editorSession) { closeEditor(editorSession) }
                .navigationTitle(source.displayName)
                .navigationSubtitle("Editing")
                .toolbar {
                    // Icon-only toolbar buttons get the system's round Liquid Glass bezel.
                    ToolbarItem(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") { closeEditor(editorSession) }
                            .help("Back to the photos")
                    }
                }
        } else {
            HStack(spacing: 0) {
                AssetGridView(source: source, selection: $selection, onOpen: { editorSession = EditorSession(assetID: $0, source: source) },
                              onAdjustDate: adjustDate, albums: albumsAction)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let notice = source.indexingNotice {
                            IndexingNoticeView(notice: notice, progress: source.indexingProgress)
                        }
                    }
                    // Without it the row settles at the grid's ideal width, one column of thumbnails.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The Info form is light: unlike the editor's, it is simply rebuilt when shown again.
                if isInspectorVisible {
                    Divider()
                    LibraryInspector(source: source, selection: selection, onAdjustDate: adjustDate)
                        .frame(width: EditorInspector.width)
                }
            }
            .navigationTitle(source.displayName)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    ThumbnailSizeSlider()
                }
                ToolbarItem {
                    ThumbnailFitToggle()
                }
                LibraryQueryToolbar(source: source)
                ToolbarItem(placement: .primaryAction) {
                    InspectorVisibilityButton(isVisible: $isInspectorVisible)
                }
            }
            .searchable(text: searchText, placement: .toolbar, prompt: "Search names and keywords")
            .searchSuggestions {}
        }
    }

    /// Image › Rating and Image › Flag: the photo open in the editor, else the grid's selection; nil
    /// when there is neither. In the grid the current values are only read for a selection small
    /// enough to resolve on every update; the photos to write are looked up when a command runs.
    private var decisionsAction: DecisionsAction? {
        let capabilities = source.capabilities
        if let editorSession {
            let model = editorSession.model
            guard let asset = model.asset else { return nil }
            return DecisionsAction(rating: asset.rating, flag: asset.flag,
                                   setRating: capabilities.contains(.rating) ? { rating in Task { await model.setRating(rating) } } : nil,
                                   setFlag: capabilities.contains(.flag) ? { flag in Task { await model.setFlag(flag) } } : nil)
        }
        guard !selection.isEmpty else { return nil }
        let shown = selection.count <= AssetInfoModel.selectionLimit ? selection.compactMap { source.asset(id: $0) } : []
        return DecisionsAction(rating: AssetInfoModel.shared(shown.map(\.rating)), flag: AssetInfoModel.shared(shown.map(\.flag)),
                               setRating: capabilities.contains(.rating) ? { decide(.rating($0)) } : nil,
                               setFlag: capabilities.contains(.flag) ? { decide(.flag($0)) } : nil)
    }

    /// Writes a decision to every selected photo, as one undoable step.
    private func decide(_ decision: LibraryDecision) {
        let assets = selection.compactMap { source.asset(id: $0) }
        Task {
            do {
                try await MetadataEditing.apply(assets.map { ($0, decision) }, in: source, undoManager: undoManager)
            } catch {
                decisionError = error.localizedDescription
            }
        }
    }

    /// Filing in albums, for the grid's context menu and the Image menu; nil without albums.
    private var albumsAction: AlbumsAction? {
        guard let albums else { return nil }
        let last = albums.editor.lastAlbumID.flatMap { albums.list.album(id: $0) }
        return AlbumsAction(list: albums.list, currentAlbumID: albums.current?.id,
                            lastAlbum: last?.id == albums.current?.id ? nil : last,
                            add: { album, ids in add(ids, to: album) },
                            create: { ids in albumDialog = .newAlbum(folderID: nil, assetIDs: ids) },
                            remove: albums.current.map { album in { ids in remove(ids, from: album) } })
    }

    /// Image › Add to Album and its neighbors: the photo open in the editor, else the grid's
    /// selection; nil when there is neither. The open photo isn't taken out of the album it is being
    /// stepped through in: removing is for the grid.
    private var albumsCommand: AlbumsCommand? {
        guard var action = albumsAction else { return nil }
        if let editorSession {
            action.remove = nil
            let id = editorSession.model.assetID
            return AlbumsCommand(action: action) { [id] }
        }
        guard !selection.isEmpty else { return nil }
        return AlbumsCommand(action: action) { Array(selection) }
    }

    private func add(_ assetIDs: [LibraryAsset.ID], to album: PhotosAlbum) {
        guard let albums, !assetIDs.isEmpty else { return }
        Task {
            do {
                try await albums.editor.add(assetIDs, toAlbum: album.id, undoManager: undoManager)
            } catch {
                decisionError = error.localizedDescription
            }
        }
    }

    private func remove(_ assetIDs: [LibraryAsset.ID], from album: PhotosAlbum) {
        guard let albums, !assetIDs.isEmpty else { return }
        Task {
            do {
                try await albums.editor.remove(assetIDs, fromAlbum: album.id, undoManager: undoManager)
                // They leave the grid: a selection of photos no longer shown would still be acted on.
                selection.subtract(assetIDs)
            } catch {
                decisionError = error.localizedDescription
            }
        }
    }

    private func adjustDate(of assets: [LibraryAsset]) {
        guard !assets.isEmpty else { return }
        dateEdit = CaptureDateEditModel(assets: assets, source: source)
    }

    /// Returns to the grid, from the editor's Close button or the toolbar's Back button.
    private func closeEditor(_ session: EditorSession) {
        // Back in the grid, the photo last edited is the one selected.
        selection = [session.model.assetID]
        editorSession = nil
    }

    private var searchText: Binding<String> {
        Binding(get: { source.query.searchText }, set: { source.query.searchText = $0 })
    }

    private var subtitle: String {
        guard !source.assets.isEmpty else { return source.query.isUnfiltered ? "" : "No matches" }
        var text = source.query.isUnfiltered ? "\(source.assets.count) photos" : "\(source.assets.count) matching photos"
        if !selection.isEmpty {
            text += " · \(selection.count) selected"
        }
        if let duration = source.lastLoadDuration {
            text += " · listed in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))"
        }
        if let progress = source.indexingProgress {
            text += " · indexing \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
        }
        return text
    }
}

/// What a Photos library gives its grid to file photos in albums.
struct AlbumFiling {
    let list: PhotosAlbumList
    let editor: PhotosAlbumEditor
    /// The album on screen when photos can be removed from it; nil in the whole library and in Favorites.
    let current: PhotosAlbum?
}

#Preview("Grid then editor") {
    LibraryContentView(source: SampleLibrarySource())
        .frame(width: 900, height: 600)
}
