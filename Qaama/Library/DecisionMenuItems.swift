import AppKit
import LibraryKit
import SwiftUI

/// The rating and the flag in a menu, with the system's own items only. Choosing the current flag
/// again clears it, and so does clicking the current star, as in the inspector; the 1 to 5 keys always
/// give their rating. Used by the grid's and the editor's
/// context menus and by the Image menu.
///
/// - In a context menu: a row of five stars filled up to the rating, the system's palette (as the
///   Finder's tags), and Remove Rating; then Pick, Reject and Remove Flag. What doesn't apply is left
///   out: the flags where the library stores none (Photos), Remove Rating and Remove Flag when no
///   photo has one.
/// - In the menu bar: Rating and Flag submenus, which stay in place, disabled when there is nothing
///   to act on, and hold the keys (1 to 5 and 0 to remove the rating; P, X and U). A key without a
///   modifier only reaches the menu when no text field took it.
///
/// A row of stars drawn by the app, filled up to the star under the pointer as Photos does, was tried
/// and dropped: SwiftUI can't put a view of our own in a menu, and handing one to AppKit meant finding
/// SwiftUI's items by their titles and hard-coding the menu's layout (see docs/PLAN.md).
struct DecisionMenuItems: View {
    /// Where the items are, which decides their form, what is left out and who holds the keys.
    enum Placement {
        case menuBar
        case contextMenu
    }

    let placement: Placement
    /// The rating of the photos acted on; nil when they differ.
    let rating: Int?
    let flag: ItemFlag?
    /// Some photo acted on has a rating, or a flag: Remove Rating and Remove Flag do something.
    let hasRating: Bool
    let hasFlag: Bool
    /// Nil where the library stores no rating, or there is no photo to rate.
    let setRating: ((Int) -> Void)?
    /// Nil where the library stores no flag, or there is no photo to flag.
    let setFlag: ((ItemFlag) -> Void)?

    var body: some View {
        switch placement {
        case .menuBar:
            Menu("Rating") { menuBarRatingItems }
                .disabled(setRating == nil)
            Menu("Flag") { flagItems }
                .disabled(setFlag == nil)
        case .contextMenu:
            if setRating != nil {
                starRow
                if hasRating {
                    removeRating
                }
            }
            if setFlag != nil {
                Divider()
                flagItems
            }
        }
    }

    /// The stars as one row of symbols, filled up to the rating, about as tall as the menu's text. The
    /// palette draws a symbol given by name or in a Label at a size of its own, larger, and ignores
    /// the font and the image scale; it keeps the size of an image given alone, enlarged by about a
    /// fifth (seen in an open menu, by a probe).
    private var starRow: some View {
        ControlGroup {
            ForEach(1 ... 5, id: \.self) { stars in
                Button {
                    setRating?(stars == rating ? 0 : stars)
                } label: {
                    // The image alone: with a Label, the palette draws the symbol at its own size.
                    Image(nsImage: Self.starImage(filled: stars <= (rating ?? 0)))
                        .accessibilityLabel(Text(Self.ratingTitle(stars)))
                }
            }
        }
        .controlGroupStyle(.palette)
    }

    /// 11 points: stars a little taller than the text's capitals, in an open menu.
    private static let starPointSize: CGFloat = 11
    private static let filledStar = symbol("star.fill")
    private static let emptyStar = symbol("star")

    private static func starImage(filled: Bool) -> NSImage {
        filled ? filledStar : emptyStar
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: starPointSize, weight: .regular)) ?? image
    }

    @ViewBuilder
    private var menuBarRatingItems: some View {
        // A key gives its rating, even again: pressing 3 twice doesn't clear it, 0 does.
        ForEach(1 ... 5, id: \.self) { stars in
            Toggle(Self.starsTitle(stars), isOn: Binding(get: { rating == stars }, set: { _ in setRating?(stars) }))
                .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
        }
        Divider()
        removeRating
            .keyboardShortcut("0", modifiers: [])
            .disabled(!hasRating)
    }

    private var removeRating: some View {
        Button("Remove Rating") { setRating?(0) }
    }

    @ViewBuilder
    private var flagItems: some View {
        flagToggle(.picked, title: "Pick", key: "p")
        flagToggle(.rejected, title: "Reject", key: "x")
        if hasFlag || placement == .menuBar {
            if placement == .menuBar {
                Divider()
            }
            Button("Remove Flag") { setFlag?(.none) }
                .keyboardShortcut(placement == .menuBar ? KeyboardShortcut("u", modifiers: []) : nil)
                .disabled(!hasFlag)
        }
    }

    private func flagToggle(_ value: ItemFlag, title: LocalizedStringKey, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(get: { flag == value }, set: { _ in setFlag?(flag == value ? .none : value) }))
            .keyboardShortcut(placement == .menuBar ? KeyboardShortcut(key, modifiers: []) : nil)
    }

    /// The rating drawn as text, five stars filled up to it: "★★★☆☆". The same width for every
    /// rating, so the items read as a scale. VoiceOver reads the characters: an accessibility label
    /// on the toggle doesn't reach the menu item (checked by a probe).
    private static func starsTitle(_ stars: Int) -> String {
        String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
    }

    private static func ratingTitle(_ stars: Int) -> LocalizedStringKey {
        stars == 1 ? "1 Star" : "\(stars) Stars"
    }
}
