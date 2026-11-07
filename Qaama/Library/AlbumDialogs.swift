import LibraryKit
import SwiftUI

/// A question about albums waiting for the user's answer: the name of a new album or folder, or
/// the confirmation of a deletion.
enum AlbumDialog {
    /// A new album in a folder (nil: at the top level), holding these photos.
    case newAlbum(folderID: String?, assetIDs: [LibraryAsset.ID])
    /// A new folder of albums in another folder (nil: at the top level).
    case newFolder(parentID: String?)
    case delete(PhotosAlbum)

    fileprivate var isNaming: Bool {
        switch self {
        case .newAlbum, .newFolder: true
        case .delete: false
        }
    }

    fileprivate var defaultName: String {
        if case .newFolder = self {
            return "Untitled Folder"
        }
        return "Untitled Album"
    }
}

extension View {
    /// Shows the dialog set in `dialog` and makes the change once answered, as one undoable step.
    /// `editor` is nil where there are no albums: nothing is ever shown then.
    func albumDialogs(_ dialog: Binding<AlbumDialog?>, editor: PhotosAlbumEditor?, error: Binding<String?>,
                      onCreated: @escaping (AlbumDialog, String) -> Void = { _, _ in },
                      onDeleted: @escaping (PhotosAlbum) -> Void = { _ in }) -> some View
    {
        modifier(AlbumDialogs(dialog: dialog, editor: editor, error: error, onCreated: onCreated, onDeleted: onDeleted))
    }
}

/// Asks for the name of a new album or folder, or confirms the deletion of an album, then has the
/// editor make the change. Shared by the sidebar and the grid.
private struct AlbumDialogs: ViewModifier {
    @Binding var dialog: AlbumDialog?
    let editor: PhotosAlbumEditor?
    /// Where a failure is reported; the caller shows it.
    @Binding var error: String?
    /// Called with what was asked for and the identifier of the album or folder created.
    let onCreated: (AlbumDialog, String) -> Void
    let onDeleted: (PhotosAlbum) -> Void

    @State private var name = ""
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .alert(namingTitle, isPresented: isPresented { $0.isNaming }, presenting: dialog) { asked in
                TextField("Name", text: $name)
                Button("Create") { create(asked) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deletionTitle, isPresented: isPresented { !$0.isNaming }, titleVisibility: .visible, presenting: dialog) { asked in
                if case let .delete(album) = asked {
                    Button("Delete Album", role: .destructive) { delete(album) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The photos stay in your library.")
            }
            .onChange(of: dialog?.isNaming) { _, isNaming in
                if isNaming == true, let dialog {
                    name = dialog.defaultName
                }
            }
    }

    private func isPresented(_ matches: @escaping (AlbumDialog) -> Bool) -> Binding<Bool> {
        Binding(get: { dialog.map(matches) ?? false }, set: {
            if !$0 {
                dialog = nil
            }
        })
    }

    private var namingTitle: String {
        if case .newFolder = dialog {
            return "New Folder"
        }
        return "New Album"
    }

    private var deletionTitle: String {
        if case let .delete(album) = dialog {
            return "Delete the album “\(album.title)”?"
        }
        return ""
    }

    private func create(_ asked: AlbumDialog) {
        guard let editor else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? asked.defaultName : typed
        Task {
            do {
                switch asked {
                case let .newAlbum(folderID, assetIDs):
                    let id = try await editor.createAlbum(titled: title, inFolder: folderID, containing: assetIDs, undoManager: undoManager)
                    onCreated(asked, id)
                case let .newFolder(parentID):
                    let id = try await editor.createFolder(titled: title, inFolder: parentID, undoManager: undoManager)
                    onCreated(asked, id)
                case .delete:
                    break
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ album: PhotosAlbum) {
        guard let editor else { return }
        Task {
            do {
                try await editor.deleteAlbum(id: album.id, undoManager: undoManager)
                onDeleted(album)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
