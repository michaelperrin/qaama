import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Where the user chose to import photos.
enum CameraImportTarget {
    /// The Apple Photos library, and an album of it to add the photos to, if any: its identifier
    /// and its title. Not a `PhotosAlbum`: one just made may not be listed yet.
    case photos(albumID: String?, title: String?)
    case folder(FolderLibrarySource, ImportLayout)
}

/// What the user chose for an import: where the photos go and what happens after.
struct CameraImportChoice {
    var target: CameraImportTarget
    /// Bring the device's videos that weren't imported yet as well.
    var includesVideos: Bool
    /// A folder every file is copied to as well, for a backup; nil for none.
    var secondCopy: URL?
    /// Delete from the device the photos that were copied, once the import is over.
    var deletesImported: Bool
    /// Eject the device once everything is copied.
    var ejects: Bool
}

/// Asks where photos of a device go before importing them: the Apple Photos library, with an album
/// found by typing part of its name or made on the spot, or one of the folders of the sidebar, filed
/// by day or not. The choices are kept for the next import.
struct CameraImportSheet: View {
    let deviceName: String
    /// When each photo to import was taken: how many there are, and the folders they will go to.
    let photoDates: [Date?]
    let folders: [FolderLibrarySource]
    let albums: PhotosAlbumList
    /// Makes the album asked for with New…, as an undoable step of the window's.
    let albumEditor: PhotosAlbumEditor
    /// The window's: a sheet has none of its own to undo with later.
    let undoManager: UndoManager?
    /// How many videos would come with the photos: those of the device that weren't imported yet,
    /// when every new photo is imported; 0 when photos were picked by hand.
    let videoCount: Int
    /// False for a device that can't delete, or a card whose lock is on.
    let canDelete: Bool
    let onImport: (CameraImportChoice) -> Void
    let onCancel: () -> Void

    /// Where the last import went: `photosDestination`, or a folder's identifier.
    @AppStorage("importDestination") private var destination = ""
    @AppStorage("importAlbumID") private var albumID = ""
    @AppStorage("importLayout") private var layout = ImportLayout.byDay
    @AppStorage("importEjectsDevice") private var ejects = false
    /// The search for the album to add the photos to.
    @State private var albumSearch: AlbumSearchRequest?
    @State private var isNamingAlbum = false
    /// Asked each time, never remembered: what it does can't be undone.
    @State private var deletesImported = false
    /// The folder of the second copies, as a bookmark the sandbox lets the app come back to;
    /// empty for none.
    @AppStorage("importSecondCopyBookmark") private var secondCopyBookmark = Data()
    @AppStorage("importIncludesVideos") private var includesVideos = true
    @State private var isChoosingSecondCopy = false
    @State private var secondCopyError: String?
    /// The album made here, which the list of albums may not hold yet.
    @State private var createdAlbum: (id: String, title: String)?

    private static let photosDestination = "photos"

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Import to", selection: Binding(get: { chosenDestination }, set: { destination = $0 })) {
                        Text("Apple Photos").tag(Self.photosDestination)
                        if !folders.isEmpty {
                            Divider()
                            ForEach(folders) { folder in
                                Text(folder.displayName).tag(folder.id.uuidString)
                            }
                        }
                    }
                    if let folder {
                        Picker("Organize", selection: $layout) {
                            // Each way by what it makes of today.
                            ForEach(ImportLayout.allCases, id: \.self) { layout in
                                if layout == .flat {
                                    Divider()
                                }
                                Text(layout.title).tag(layout)
                            }
                        }
                        .help(folder.folderURL.path(percentEncoded: false))
                        if layout != .flat {
                            LabeledContent("Folders") { folderPreview }
                        }
                    } else {
                        LabeledContent("Album") {
                            HStack(spacing: 6) {
                                Text(albumTitle ?? "None")
                                    .foregroundStyle(albumTitle == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                if albumTitle != nil {
                                    Button("No Album", systemImage: "xmark.circle.fill") { albumID = "" }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .help("Import without adding to an album")
                                }
                                Button("Choose…") {
                                    albumSearch = AlbumSearchRequest(assetIDs: [], model: PhotosAlbumPickerModel(tree: albums.tree))
                                }
                                .disabled(!albums.isLoaded)
                                Button("New…") { isNamingAlbum = true }
                                    .disabled(!albums.isLoaded)
                                    .help("Make a new album, in a folder of albums or not")
                            }
                        }
                    }
                    if videoCount > 0 {
                        Toggle(videoCount == 1 ? "Import the video too" : "Import the \(videoCount.formatted()) videos too", isOn: $includesVideos)
                            .help("Videos are copied with the photos; once imported, Qaama doesn't list them")
                    }
                    LabeledContent("Second copy") {
                        HStack(spacing: 6) {
                            Text(secondCopy?.lastPathComponent ?? "None")
                                .foregroundStyle(secondCopy == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if secondCopy != nil {
                                Button("No Second Copy", systemImage: "xmark.circle.fill") { secondCopyBookmark = Data() }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Import without a second copy")
                            }
                            Button("Choose…") { isChoosingSecondCopy = true }
                        }
                    }
                    .help(secondCopy.map { "Every file is copied to \($0.path(percentEncoded: false)) as well, in a folder per day" }
                        ?? "A folder, on another disk for instance, every file is copied to as well")
                    Toggle("Delete from “\(deviceName)” what was imported", isOn: $deletesImported)
                        .disabled(!canDelete)
                        .help(canDelete ? "Once the import is over, the photos that were copied are deleted from the device, for good. Those that couldn't be copied stay."
                            : "“\(deviceName)” is locked, or can't delete photos")
                    Toggle("Eject “\(deviceName)” when done", isOn: $ejects)
                } header: {
                    Text(photoCount == 1 ? "Import 1 photo from “\(deviceName)”" : "Import \(photoCount.formatted()) photos from “\(deviceName)”")
                } footer: {
                    if let secondCopyError {
                        Text(secondCopyError).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            // As tall as its rows: a grouped form otherwise takes all the height it is offered.
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let photos = CameraImportTarget.photos(albumID: albumTitle == nil ? nil : albumID, title: albumTitle)
                    onImport(CameraImportChoice(target: folder.map { .folder($0, layout) } ?? photos, includesVideos: includesVideos && videoCount > 0,
                                                secondCopy: secondCopy,
                                                deletesImported: deletesImported && canDelete, ejects: ejects))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        // The same search as Add to Album: part of a name, the arrow keys, Return.
        .sheet(item: $albumSearch) { request in
            AlbumSearchView(model: request.model, photoCount: photoCount, onPick: { picked in
                albumID = picked.id
                albumSearch = nil
            }, onCancel: { albumSearch = nil })
        }
        .fileImporter(isPresented: $isChoosingSecondCopy, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                // The bookmark is made while the picker's access holds.
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                secondCopyBookmark = try SecurityBookmark.make(for: url)
                secondCopyError = nil
            } catch {
                secondCopyError = "The folder can't be used for second copies: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $isNamingAlbum) {
            NewAlbumSheet(folders: PhotosAlbumFolderChoice.all(in: albums.tree), editor: albumEditor, undoManager: undoManager, onCreated: { id, title in
                createdAlbum = (id, title)
                albumID = id
                isNamingAlbum = false
            }, onCancel: { isNamingAlbum = false })
        }
    }

    private var photoCount: Int {
        photoDates.count
    }

    /// The folders the photos will go to, with how many photos each: a list of a few lines, which
    /// scrolls beyond.
    private var folderPreview: some View {
        let planned = layout.folders(for: photoDates)
        return ScrollView {
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(planned) { folder in
                    HStack(spacing: 8) {
                        Text(folder.subfolder ?? "(no date)")
                        Text(folder.count.formatted())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: min(CGFloat(planned.count) * 20, 104))
    }

    /// What the picker shows: the destination of the last import while it still exists, else the
    /// first folder, else the Photos library.
    private var chosenDestination: String {
        if destination == Self.photosDestination || folders.contains(where: { $0.id.uuidString == destination }) {
            return destination
        }
        return folders.first?.id.uuidString ?? Self.photosDestination
    }

    /// The folder chosen; nil when the photos go to the Photos library.
    private var folder: FolderLibrarySource? {
        folders.first { $0.id.uuidString == chosenDestination }
    }

    /// The folder of the second copies, while its bookmark still leads somewhere (a disk that is
    /// unplugged doesn't).
    private var secondCopy: URL? {
        secondCopyBookmark.isEmpty ? nil : (try? SecurityBookmark.resolve(secondCopyBookmark))?.url
    }

    /// The title of the album chosen last, while it still exists; nil without an album.
    private var albumTitle: String? {
        guard !albumID.isEmpty else { return nil }
        return albums.album(id: albumID)?.title ?? (createdAlbum?.id == albumID ? createdAlbum?.title : nil)
    }
}

private extension ImportLayout {
    /// What the Organize menu calls this way of filing, with what it makes of today.
    var title: String {
        let example = subfolder(for: .now) ?? ""
        return switch self {
        case .byDay: "Year, then day (\(example))"
        case .yearMonthDay: "Year, month, day (\(example))"
        case .yearMonth: "Year, month (\(example))"
        case .year: "Year (\(example))"
        case .day: "Day (\(example))"
        case .flat: "No subfolders"
        }
    }
}

/// Asks for the name of a new album and the folder of albums to make it in, and makes it.
struct NewAlbumSheet: View {
    /// The folders an album can go in, in the sidebar's order.
    let folders: [PhotosAlbumFolderChoice]
    let editor: PhotosAlbumEditor
    let undoManager: UndoManager?
    /// Called with the identifier and the title of the album made.
    let onCreated: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name = "Untitled Album"
    /// Nil: at the top level.
    @State private var folderID: String?
    @State private var error: String?
    @State private var isCreating = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .onSubmit(create)
                    if !folders.isEmpty {
                        Picker("In", selection: $folderID) {
                            Text("Albums").tag(String?.none)
                            Divider()
                            ForEach(folders) { folder in
                                // A menu has no outline: the depth shows as an indent.
                                Text(String(repeating: "    ", count: folder.depth) + folder.title).tag(Optional(folder.id))
                            }
                        }
                    }
                } header: {
                    Text("New Album")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
        .onAppear { isNameFocused = true }
    }

    private func create() {
        guard !isCreating else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? "Untitled Album" : typed
        isCreating = true
        Task {
            do {
                let id = try await editor.createAlbum(titled: title, inFolder: folderID, undoManager: undoManager)
                onCreated(id, title)
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// The bar above a device's grid while photos are imported from it, and after: how far the import
/// is with a way to stop it, then what it did.
struct CameraImportBar: View {
    let job: CameraImport
    /// Hides the bar once the import is over.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if job.isFinished {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(job.failures.joined(separator: "\n"))
                Spacer(minLength: 0)
                Button("Done", action: onDismiss)
                    .controlSize(.small)
            } else {
                ProgressView(value: job.progress.fraction)
                    .controlSize(.small)
                    .frame(width: 90)
                Text("Importing \(min(job.done + 1, job.total).formatted()) of \(job.total.formatted()) into “\(job.destinationName)”…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Stop") { job.cancel() }
                    .controlSize(.small)
                    .help("Stop after the photo being copied; what was copied stays")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summary: String {
        Self.summary(imported: job.importedCount, videos: job.importedVideos, alreadyThere: job.alreadyThere, failed: job.failures.count,
                     left: job.isCancelled ? job.total - job.done : 0, destination: job.destinationName)
    }

    /// "Imported 238 photos into “Photos”. 2 were already there. 1 file couldn't be copied."
    static func summary(imported: Int, videos: Int = 0, alreadyThere: Int, failed: Int, left: Int, destination: String) -> String {
        // Videos count among the items, and are told apart in a sentence of their own.
        let noun = videos > 0 ? (imported == 1 ? "item" : "items") : (imported == 1 ? "photo" : "photos")
        var sentences = ["Imported \(imported.formatted()) \(noun) into “\(destination)”."]
        if alreadyThere > 0 {
            sentences.append(alreadyThere == 1 ? "1 was already there." : "\(alreadyThere.formatted()) were already there.")
        }
        if failed > 0 {
            sentences.append(failed == 1 ? "1 file couldn't be copied." : "\(failed.formatted()) files couldn't be copied.")
        }
        if videos > 0 {
            sentences.append(videos == 1 ? "1 of them is a video." : "\(videos.formatted()) of them are videos.")
        }
        if left > 0 {
            sentences.append(left == 1 ? "Stopped with 1 photo left." : "Stopped with \(left.formatted()) photos left.")
        }
        return sentences.joined(separator: " ")
    }
}

#Preview("Import sheet, no folder") {
    CameraImportSheet(deviceName: "EOS_DIGITAL", photoDates: Array(repeating: Date.now, count: 24), folders: [], albums: PhotosAlbumList(),
                      albumEditor: PhotosAlbumEditor(library: PhotoKitAlbumLibrary()), undoManager: nil, videoCount: 3, canDelete: true, onImport: { _ in }, onCancel: {})
}
