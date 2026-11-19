import LibraryKit
import SwiftUI

/// A card or a camera plugged in: its photos in the grid, to look at before importing them. The
/// device is read when first shown. While it lists its files, the grid already has its size, made of
/// empty thumbnails that fill as photos are found; the photos take their places, by date, once they
/// are all known. A double click, or the space bar, shows a photo large (`CameraPhotoViewer`).
///
/// The toolbar's Import button copies the selected photos, or all of them, into the Apple Photos
/// library or one of the folders of the sidebar; the import goes on while the window shows something
/// else, and can be undone.
struct CameraLibraryView: View {
    let source: CameraLibrarySource
    /// Where photos can be imported: its folders, and the Photos library with its albums.
    let catalog: LibraryCatalog
    @State private var selection: Set<LibraryAsset.ID> = []
    /// The photo shown large in place of the grid, if any.
    @State private var viewedID: LibraryAsset.ID?
    /// Where the grid is scrolled, for the grid that comes back after the viewer.
    @State private var gridPlace = GridPlaceKeeper()
    @State private var isChoosingDestination = false
    /// The import whose result the user has read: its bar is gone.
    @State private var dismissedImportID: CameraImport.ID?
    @State private var ejectError: String?
    /// The photos to delete from the device once the user has confirmed.
    @State private var deletion: DeletionRequest?
    @State private var deletionError: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            switch source.state {
            case .listed:
                if let viewedID {
                    CameraPhotoViewer(source: source, assetID: viewedID, onClose: closeViewer)
                } else {
                    grid
                }
            case let .unavailable(reason):
                // What was listed before the device left stays to look at.
                if source.assets.isEmpty {
                    ContentUnavailableView {
                        Label("Device Unavailable", systemImage: "sdcard")
                    } description: {
                        Text(reason)
                    }
                    .navigationTitle(source.displayName)
                } else {
                    grid.safeAreaInset(edge: .top, spacing: 0) {
                        IndexingNoticeView(notice: reason, progress: nil)
                    }
                }
            case .idle, .listing:
                Group {
                    if let progress = source.listingProgress {
                        CameraReadingGrid(source: source, count: progress.total)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                IndexingNoticeView(notice: "Reading “\(source.displayName)”…", progress: progress)
                            }
                    } else {
                        ProgressView("Reading “\(source.displayName)”…")
                    }
                }
                .navigationTitle(source.displayName)
                .navigationSubtitle(subtitle)
            }
        }
        .task { await source.load() }
        .sheet(isPresented: $isChoosingDestination) {
            CameraImportSheet(deviceName: source.displayName, photoDates: photosToImport.map(\.creationDate), folders: catalog.folders,
                              albums: catalog.photosAlbums, albumEditor: catalog.photosAlbumEditor, undoManager: undoManager, onImport: { choice in
                                  isChoosingDestination = false
                                  startImport(choice)
                              }, onCancel: { isChoosingDestination = false })
        }
        .alert("Couldn't Eject “\(source.displayName)”", isPresented: Binding(get: { ejectError != nil }, set: {
            if !$0 {
                ejectError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ejectError ?? "")
        }
        .deletionConfirmation($deletion, onConfirm: delete)
        .alert("Couldn't Delete from “\(source.displayName)”", isPresented: Binding(get: { deletionError != nil }, set: {
            if !$0 {
                deletionError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        // Image › Delete acts on the grid's selection, as in a library.
        .focusedSceneValue(\.photoFilingAction, viewedID == nil && source.capabilities.contains(.deletion) && !selection.isEmpty
            ? PhotoFilingAction(count: selection.count, duplicate: nil, delete: { askToDelete(Array(selection)) }) : nil)
    }

    /// The selected photos in the grid's order, imported before or not; when none is selected,
    /// the photos that weren't imported yet.
    private var photosToImport: [LibraryAsset] {
        selection.isEmpty ? source.assets.filter { !$0.isImported } : source.assets(withIDs: selection)
    }

    /// What the Import button says it will bring.
    private var importTitle: String {
        if !selection.isEmpty {
            return "Import \(selection.count.formatted()) Selected…"
        }
        return source.newPhotoCount == source.assets.count ? "Import All…" : "Import \(source.newPhotoCount.formatted()) New…"
    }

    private var isImporting: Bool {
        source.currentImport?.isFinished == false
    }

    /// Copies the photos, then, once done: the destination registers the undo (a folder also lists
    /// its new files at once), and the device is ejected if asked and nothing went wrong. The
    /// import outlives this view.
    private func startImport(_ choice: CameraImportChoice) {
        let destination: ImportDestination
        let name: String
        switch choice.target {
        case let .folder(folder, layout):
            destination = .folder(folder.folderURL, layout: layout)
            name = folder.displayName
        case let .photos(albumID, title):
            destination = .library(catalog.photos.importer(intoAlbum: albumID))
            name = title ?? "Photos"
        }
        guard let job = source.startImport(of: photosToImport, into: destination, named: name) else { return }
        let (source, photos, history, undoManager) = (source, catalog.photos, catalog.cameras.history, undoManager)
        Task {
            await job.wait()
            // Both undos are registered in the same turn: one step of the Edit menu takes the
            // photos back and makes them new again on the device.
            switch choice.target {
            case let .folder(folder, _):
                folder.registerImport(of: job.imported, undoManager: undoManager)
                let root = folder.folderURL.path(percentEncoded: false)
                let paths = job.imported.map { String($0.path(percentEncoded: false).dropFirst(root.count)).trimmingCharacters(in: ["/"]) }
                history?.record(ImportRecord(deviceName: source.displayName, destination: .folder(id: folder.id), relativePaths: paths),
                                files: job.importedFiles, undoManager: undoManager)
            case let .photos(albumID, _):
                photos.registerImport(of: job.createdPhotoIDs, undoManager: undoManager)
                history?.record(ImportRecord(deviceName: source.displayName, destination: .photos(albumID: albumID), photoIDs: job.createdPhotoIDs),
                                files: job.importedFiles, isRedoable: false, undoManager: undoManager)
            }
            guard choice.ejects, !job.isCancelled, job.failures.isEmpty else { return }
            do {
                try await source.eject()
            } catch {
                ejectError = error.localizedDescription
            }
        }
    }

    /// The grid with its title and its toolbar; the viewer that takes its place has its own.
    private var grid: some View {
        AssetGridView(source: source, selection: $selection, onOpen: view, onDelete: askToDelete, place: gridPlace)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let job = source.currentImport, job.id != dismissedImportID {
                    CameraImportBar(job: job) { dismissedImportID = job.id }
                }
            }
            // The space bar shows the selected photo, as it previews a file in the Finder. The
            // grid has the keyboard focus; what it doesn't handle comes up here.
            .onKeyPress(.space) {
                guard selection.count == 1, let id = selection.first else { return .ignored }
                view(id)
                return .handled
            }
            .navigationTitle(source.displayName)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    ThumbnailFitToggle()
                }
                ToolbarItem {
                    ThumbnailSizeSlider()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(importTitle) { isChoosingDestination = true }
                        .disabled(isImporting || (selection.isEmpty && source.newPhotoCount == 0))
                        .help(selection.isEmpty
                            ? (source.newPhotoCount == 0 ? "Every photo was imported already: select photos to import them again"
                                : "Import the photos that weren't imported yet into Photos or a folder")
                            : "Import the selected photos into Photos or a folder")
                }
            }
    }

    /// Deleting from a device can't be undone: always asked first.
    private func askToDelete(_ assetIDs: [LibraryAsset.ID]) {
        let assets = source.assets(withIDs: assetIDs)
        guard !assets.isEmpty, let notice = source.deletionNotice(for: assets) else { return }
        deletion = DeletionRequest(assets: assets, notice: notice)
    }

    private func delete(_ assets: [LibraryAsset]) {
        Task {
            do {
                try await source.delete(assets, undoManager: undoManager)
            } catch {
                deletionError = error.localizedDescription
            }
            // Whatever was deleted is no longer there to be selected.
            selection = selection.filter { source.asset(id: $0) != nil }
        }
    }

    private func view(_ id: LibraryAsset.ID) {
        gridPlace.open(id, leavingGridAt: gridPlace.read())
        viewedID = id
    }

    /// Back to the grid, where it was, or around the photo the viewer stepped to; that photo is
    /// selected, so the arrow keys go on from it.
    private func closeViewer(on id: LibraryAsset.ID) {
        selection = [id]
        gridPlace.close(on: id, row: source.index(of: id))
        viewedID = nil
    }

    private var subtitle: String {
        guard source.state != .listing, source.state != .idle else {
            return source.listingProgress.map { "About \($0.total.formatted()) photos" } ?? ""
        }
        let count = source.assets.count
        var photos = count == 1 ? "1 photo" : "\(count.formatted()) photos"
        // Only once some were imported: before that, they are all new.
        if source.newPhotoCount < count {
            photos += " · \(source.newPhotoCount.formatted()) new"
        }
        return source.movieCount > 0 ? "\(photos) · \(source.movieCount.formatted()) videos not shown" : photos
    }
}

/// The grid a device's photos will fill, while the device is being read: as many thumbnails as it is
/// expected to hold, laid out as `AssetGridView` lays the photos out (same size from the toolbar's
/// slider, same spacing), so the window already shows how much there is. The first ones show the
/// photos found so far, in the order the device announces them, which is not the order the grid
/// will list them in: a photo's place depends on the dates of all the others. Nothing can be
/// selected yet.
private struct CameraReadingGrid: View {
    let source: CameraLibrarySource
    /// How many photos the device is expected to hold.
    let count: Int
    @AppStorage(GridDisplay.thumbnailSideKey) private var thumbnailSide = GridDisplay.defaultSide
    @AppStorage(GridDisplay.thumbnailFitKey) private var thumbnailFit = ThumbnailFit.fill

    var body: some View {
        let side = CGFloat(thumbnailSide)
        let found = source.foundPhotos
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: GridViewport.spacing)], spacing: GridViewport.spacing) {
                // The estimate can fall short of what is found in the end.
                ForEach(0 ..< max(count, found.count), id: \.self) { index in
                    CameraReadingCell(asset: index < found.count ? found[index] : nil, source: source, side: side, fit: thumbnailFit)
                }
            }
            .padding(GridViewport.padding)
        }
        .accessibilityLabel("Reading the photos")
    }
}

/// One thumbnail of the grid shown while a device is read: empty, or the photo found for it, by the
/// thumbnail its file embeds. The shape of `AssetThumbnailView`, without what a photo of a library
/// has (selection, badges, menu).
private struct CameraReadingCell: View {
    let asset: LibraryAsset?
    let source: CameraLibrarySource
    let side: CGFloat
    let fit: ThumbnailFit

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        let size = fit.displaySize(inSquare: side, aspectRatio: image.map { Double($0.width) / Double($0.height) } ?? 1)
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 6))
        .frame(width: side + 2 * SelectionRing.width, height: side + 2 * SelectionRing.width)
        .task(id: asset?.id) {
            guard let asset else { return }
            let loaded = await source.quickThumbnail(for: asset)
            if !Task.isCancelled, let loaded {
                image = loaded
            }
        }
    }
}

#Preview("Reading") {
    CameraReadingGrid(source: CameraLibrarySource(connection: PreviewCard()), count: 240)
        .frame(width: 800, height: 500)
}

/// A device that never answers, for the preview of the grid shown while one is read.
private final class PreviewCard: CameraConnection {
    let id = "preview"
    let name = "CARD"
    let kind = CameraDeviceKind.card
    var onEvent: ((CameraEvent) -> Void)?
    func open() {}
    func close() {}
    func head(of _: CameraFile.ID, length _: Int) async -> Data? {
        nil
    }

    func thumbnailData(of _: CameraFile.ID, maxPixelSize _: Int) async -> Data? {
        nil
    }

    func download(_ id: CameraFile.ID, into _: URL) async throws -> URL {
        throw CameraImportError.notDownloaded(id)
    }

    func eject() async throws {}

    let canDelete = false
    func delete(_: [CameraFile.ID]) async throws -> [CameraFile.ID] {
        []
    }
}
