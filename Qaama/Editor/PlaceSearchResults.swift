import EditorKit
import SwiftUI

/// What a search for a place found, while something is typed: the results as rows, each picked by
/// a click, or word that it is still searching or found nothing. One row per result, so the list
/// reads as rows in a form and as lines in a stack alike. A search that failed shows nothing here:
/// the view holding the field says why.
struct PlaceSearchResults: View {
    let search: PlaceSearchModel
    let onPick: (PlaceSuggestion) -> Void

    var body: some View {
        if search.hasQuery {
            if search.suggestions.isEmpty {
                HStack(spacing: 6) {
                    if search.isSearching {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                    } else if search.errorMessage == nil {
                        Text("No places found")
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(search.suggestions) { suggestion in
                    PlaceSuggestionRow(suggestion: suggestion, isHighlighted: suggestion.id == search.highlightedID) {
                        onPick(suggestion)
                    }
                }
            }
        }
    }
}

/// One place found by the search: its name and, dimmed, where it is. Chosen by a click, or by
/// Return when highlighted (the arrow keys move the highlight from the search field).
private struct PlaceSuggestionRow: View {
    let suggestion: PlaceSuggestion
    let isHighlighted: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .lineLimit(1)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The colors of a selected row in a list that has the keyboard, as the system draws it.
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
            .background(isHighlighted ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help([suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
