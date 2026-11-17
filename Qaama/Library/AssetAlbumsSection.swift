import LibraryKit
import SwiftUI

/// The albums the photos of an Info panel are in, each one click away: those of the photo, or with
/// several photos those they are all in, as for keywords. Shown for photos of a library that has
/// albums (Photos), in a window that can go to them. Shared by the grid's Info panel and the
/// editor's Info tab.
///
/// Only the albums of the sidebar are named: Favorites is a smart album, and the shared and synced
/// albums Photos also answers with can't be opened here.
struct AssetAlbumsSection: View {
    let source: any LibrarySource
    let assets: [LibraryAsset]

    @State private var model = AssetAlbumsModel()
    @Environment(\.albumNavigation) private var navigation

    /// What the albums are read for: these photos, and again when an album gains or loses photos.
    /// Not the photos themselves: a rating changes them, not where they are filed.
    private struct Reading: Hashable {
        let assetIDs: [LibraryAsset.ID]
        let contentVersion: Int
    }

    var body: some View {
        if let navigation, !assets.isEmpty, assets.allSatisfy(source.hasAlbums(for:)) {
            Section {
                if model.isShowing(assets), let ids = model.albumIDs {
                    let albums = PhotosAlbumSearch.Match.all(in: navigation.list.tree) { ids.contains($0.id) }
                    if albums.isEmpty {
                        Text(Self.noneText(count: assets.count)).foregroundStyle(.secondary)
                    }
                    ForEach(albums) { match in
                        AlbumRow(match: match, open: match.id == navigation.currentID ? nil : { navigation.open(match.id) })
                    }
                } else {
                    // A line is kept while the albums are read (a few ms): the map below doesn't jump.
                    Text(Self.noneText(count: assets.count)).hidden()
                }
            } header: {
                Text(assets.count == 1 ? "Albums" : "Albums in Common")
                    // On the header: a modifier of the section would be applied to each of its rows.
                    .task(id: Reading(assetIDs: assets.map(\.id), contentVersion: navigation.list.contentVersion)) {
                        await model.show(assets, in: source)
                    }
            }
        }
    }

    private static func noneText(count: Int) -> String {
        count == 1 ? "Not in any album" : "No album in common"
    }
}

/// One album a photo is in: its title above the folders it is in. The whole line goes to the
/// album, which the arrow at its end tells. No link: the system's is a fixed blue, too loud next
/// to photos in a list that can be long.
private struct AlbumRow: View {
    let match: PhotosAlbumSearch.Match
    /// Goes to the album; nil for the album on screen.
    let open: (() -> Void)?

    var body: some View {
        Group {
            if let open {
                Button(action: open) {
                    HStack(spacing: 6) {
                        label
                        Image(systemName: "arrow.forward.circle")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the album")
            } else {
                label
            }
        }
        // The whole of what may be truncated.
        .help((match.folders + [match.album.title]).joined(separator: " › "))
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.secondary)
                // The same column as the sidebar's symbols: the titles stay aligned.
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.album.title)
                    .lineLimit(1)
                    // Long titles often differ by their end (a year): keep both ends.
                    .truncationMode(.middle)
                if !match.folders.isEmpty {
                    Text(match.folders.joined(separator: " › "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The folder the album is in matters most.
                        .truncationMode(.head)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A library whose first photos are filed in the albums of `previewAlbums`.
@MainActor private func previewSource() -> SampleLibrarySource {
    let source = SampleLibrarySource()
    source.albumIDsByAsset = ["sample-0": ["a1", "a2", "a3"], "sample-1": ["a3"]]
    return source
}

@MainActor private let previewAlbums = PhotosAlbumList(tree: [
    .folder(id: "f1", title: "Travels", children: [
        .folder(id: "f2", title: "Asia", children: [.album(PhotosAlbum(id: "a1", title: "Japan 2024", kind: .user, estimatedCount: 0))]),
        .album(PhotosAlbum(id: "a2", title: "Iceland", kind: .user, estimatedCount: 0)),
    ]),
    .album(PhotosAlbum(id: "a3", title: "Portfolio", kind: .user, estimatedCount: 0)),
])

#Preview("One photo, in the Portfolio album") {
    let source = previewSource()
    Form {
        AssetAlbumsSection(source: source, assets: [source.asset(id: "sample-0")!])
    }
    .formStyle(.grouped)
    .environment(\.albumNavigation, AlbumNavigation(list: previewAlbums, currentID: "a3", open: { _ in }))
    .frame(width: EditorInspector.width, height: 300)
}

#Preview("Several photos") {
    let source = previewSource()
    Form {
        AssetAlbumsSection(source: source, assets: ["sample-0", "sample-1"].compactMap { source.asset(id: $0) })
        AssetAlbumsSection(source: source, assets: [source.asset(id: "sample-2")!])
    }
    .formStyle(.grouped)
    .environment(\.albumNavigation, AlbumNavigation(list: previewAlbums, open: { _ in }))
    .frame(width: EditorInspector.width, height: 300)
}
