import AppKit
import LibraryKit
import SwiftUI

/// An Add to Album search in progress: the photos to file and what is being typed.
struct AlbumSearchRequest: Identifiable {
    let id = UUID()
    let assetIDs: [LibraryAsset.ID]
    let model: PhotosAlbumPickerModel
}

/// The Add to Album search: a field for part of an album's name and, below it, the albums it finds
/// in every folder. Return files the photos in the highlighted album, the arrow keys move the
/// highlight, a click on an album chooses it.
///
/// The keyboard stays in the field the whole time, as in a menu being typed in: the list is drawn
/// by hand so its highlight can follow the arrow keys without taking the focus.
struct AlbumSearchView: View {
    @Bindable var model: PhotosAlbumPickerModel
    let photoCount: Int
    let onPick: (PhotosAlbum) -> Void
    let onCancel: () -> Void

    /// Read once: the size being remembered while the sheet is resized mustn't feed back into it.
    @State private var openingSize = AlbumSearchSize.remembered

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to Album").font(.headline)
                Text(photoCount == 1 ? "1 photo" : "\(photoCount) photos")
                    .foregroundStyle(.secondary)
            }
            field
            results
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: pickHighlighted)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.highlightedID == nil)
            }
        }
        .padding(20)
        // Resizable: long album names are common, and more room shows more of them. A sheet is
        // only resizable when it is fitted to a content that is flexible; the ideal size is the
        // one it opens at, the one it was last given.
        .frame(minWidth: 380, idealWidth: openingSize.width, maxWidth: 900,
               minHeight: 280, idealHeight: openingSize.height, maxHeight: 1000)
        .presentationSizing(.fitted)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { AlbumSearchSize.remember($0) }
    }

    private var field: some View {
        SearchField(text: $model.query, prompt: "Album or folder name", onMove: { model.moveHighlight(by: $0) }, onSubmit: pickHighlighted)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.matches) { match in
                        AlbumSearchRow(match: match, isHighlighted: match.id == model.highlightedID) { onPick(match.album) }
                            .id(match.id)
                    }
                }
                .padding(4)
            }
            .onChange(of: model.highlightedID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
        // Takes whatever height the sheet has beyond the field and the buttons.
        .frame(maxHeight: .infinity)
        .overlay {
            if model.matches.isEmpty {
                Text(model.albumCount == 0 ? "No Albums" : "No Albums Found")
                    .foregroundStyle(.secondary)
            }
        }
        .background(.background, in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator) }
    }

    private func pickHighlighted() {
        if let album = model.highlighted {
            onPick(album)
        }
    }
}

/// The size of the search sheet, kept between uses and sessions.
private enum AlbumSearchSize {
    private static let widthKey = "albumSearchWidth"
    private static let heightKey = "albumSearchHeight"
    /// Room for ten albums.
    private static let initial = CGSize(width: 480, height: 430)

    static var remembered: CGSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: widthKey), height = defaults.double(forKey: heightKey)
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : initial
    }

    static func remember(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        UserDefaults.standard.set(size.width, forKey: widthKey)
        UserDefaults.standard.set(size.height, forKey: heightKey)
    }
}

/// One album found: its title and, dimmed, the folders it is in, each with the symbol it has in
/// the sidebar. Chosen by a click.
private struct AlbumSearchRow: View {
    static let height: CGFloat = 26

    let match: PhotosAlbumSearch.Match
    let isHighlighted: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(dimmed)
                    // Symbols differ in width: the titles stay aligned.
                    .frame(width: 20)
                TitleAndDetailLayout(spacing: 12, maxDetailWidth: 170) {
                    Text(match.album.title)
                        .lineLimit(1)
                        // Long titles often differ by their end (a year): keep both ends.
                        .truncationMode(.middle)
                    if !match.folders.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .imageScale(.small)
                            Text(match.folders.joined(separator: " › "))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .font(.callout)
                        .foregroundStyle(dimmed)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            // The colors of a selected row in a list that has the keyboard, as the system draws it.
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
            .background(isHighlighted ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The whole of what may be truncated.
        .help((match.folders + [match.album.title]).joined(separator: " › "))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// The color of what comes second to the title, on the highlight or off it.
    private var dimmed: AnyShapeStyle {
        isHighlighted ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8)) : AnyShapeStyle(.secondary)
    }
}

/// A title at the leading edge and a detail at the trailing edge of one line, for single-line
/// texts. The detail gets the width it asks for up to `maxDetailWidth`, the title the rest, and
/// what the title doesn't use goes back to the detail: nothing is truncated while the row has room,
/// and a long title can't squeeze the detail out. A `frame(maxWidth:)` on the detail would take
/// that width even when the detail is short, truncating titles next to empty space.
private struct TitleAndDetailLayout: Layout {
    let spacing: CGFloat
    let maxDetailWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? ideal, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let title = subviews.first else { return }
        var titleWidth = min(title.sizeThatFits(.unspecified).width, bounds.width)
        if subviews.count > 1 {
            let detail = subviews[1]
            let available = max(bounds.width - spacing, 0)
            let detailIdeal = detail.sizeThatFits(.unspecified).width
            titleWidth = min(titleWidth, max(available - min(detailIdeal, maxDetailWidth), 0))
            detail.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                         proposal: ProposedViewSize(width: min(detailIdeal, available - titleWidth), height: bounds.height))
        }
        title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: titleWidth, height: bounds.height))
    }
}

#Preview("Album search") {
    let tree: [PhotosAlbumNode] = [
        .folder(id: "f1", title: "Travels", children: [
            .folder(id: "f2", title: "Asia", children: [.album(PhotosAlbum(id: "a1", title: "Japan 2024", kind: .user, estimatedCount: 0))]),
            .album(PhotosAlbum(id: "a2", title: "Iceland", kind: .user, estimatedCount: 0)),
        ]),
        .album(PhotosAlbum(id: "a3", title: "Portfolio", kind: .user, estimatedCount: 0)),
    ]
    AlbumSearchView(model: PhotosAlbumPickerModel(tree: tree), photoCount: 3, onPick: { _ in }, onCancel: {})
}
