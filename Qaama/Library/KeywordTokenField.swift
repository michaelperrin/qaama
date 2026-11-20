import AppKit
import SwiftUI

/// A field of keywords as tokens: each keyword in its own rounded box, picked among those already
/// in use as one types, or made by typing a new one and a comma or Return. The system's token field
/// (`NSTokenField`), as Mail's recipients and the Finder's tags are: SwiftUI has none.
///
/// The keywords are told at every change, a keyword being typed included, so nothing is lost when
/// the sheet's button is clicked without leaving the field. A flat list for now: a hierarchy of
/// keywords is wished for later, and nothing here reserves a separator but the comma that ends one.
struct KeywordTokenField: NSViewRepresentable {
    @Binding var keywords: [String]
    /// The keywords in use, offered as completions.
    var suggestions: [String] = []
    var placeholder = "Add keywords"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.tokenStyle = .rounded
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.completionDelay = 0.1
        // Several lines when the keywords don't fit on one.
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.objectValue = keywords
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // What the field reported itself is already in it, a keyword half typed included; anything
        // else came from outside (a keyword picked in the list next to it) and is shown at once.
        if keywords != context.coordinator.reported, Coordinator.keywords(in: field) != keywords {
            field.objectValue = keywords
            context.coordinator.reported = keywords
        }
    }

    /// As tall as its tokens take at the width offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTokenField, context _: Context) -> CGSize? {
        let width = proposal.width ?? 240
        guard width.isFinite, width > 0, let cell = field.cell else { return nil }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height
        return CGSize(width: width, height: max(height, 22))
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: KeywordTokenField
        /// What the field last told its owner.
        var reported: [String]

        init(_ parent: KeywordTokenField) {
            self.parent = parent
            reported = parent.keywords
        }

        /// The keywords of the field, each once, trimmed, in the order typed.
        static func keywords(in field: NSTokenField) -> [String] {
            cleaned((field.objectValue as? [Any] ?? []).compactMap { $0 as? String })
        }

        static func cleaned(_ keywords: [String]) -> [String] {
            var seen: Set<String> = []
            return keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }

        func controlTextDidChange(_ notification: Notification) {
            report(notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            report(notification)
        }

        private func report(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let keywords = Self.keywords(in: field)
            reported = keywords
            if keywords != parent.keywords {
                parent.keywords = keywords
            }
        }

        /// The keywords in use that hold what is typed, those that start with it first; none of
        /// those already in the field. Nothing is selected: Return keeps what was typed.
        func tokenField(_ field: NSTokenField, completionsForSubstring substring: String, indexOfToken _: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]?
        {
            selectedIndex?.pointee = -1
            return Self.completions(for: substring, among: parent.suggestions, excluding: Self.keywords(in: field))
        }

        static func completions(for typed: String, among suggestions: [String], excluding present: [String]) -> [String] {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let taken = Set(present.map { $0.lowercased() })
            let free = suggestions.filter { !taken.contains($0.lowercased()) }
            let starting = free.filter { $0.range(of: typed, options: options.union(.anchored)) != nil }
            let holding = free.filter { $0.range(of: typed, options: options) != nil && !starting.contains($0) }
            return Array((starting + holding).prefix(12))
        }

        /// A keyword already in the field isn't added again.
        func tokenField(_ field: NSTokenField, shouldAdd tokens: [Any], at _: Int) -> [Any] {
            let present = Set(Self.keywords(in: field).map { $0.lowercased() })
            var seen: Set<String> = []
            return tokens.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                // The token being added is already counted in the field's value once: only a second one is a repeat.
                .filter { keyword in present.contains(keyword.lowercased()) ? Self.keywords(in: field).filter { $0.lowercased() == keyword.lowercased() }.count <= 1 : true }
        }
    }
}

/// Keywords to give photos: the token field, and next to it a button that shows every keyword in
/// use, to pick from without typing.
struct KeywordsEditor: View {
    @Binding var keywords: [String]
    /// The keywords in use in the libraries.
    var known: [String] = []

    @State private var isBrowsing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            KeywordTokenField(keywords: $keywords, suggestions: known)
            Button("Choose Keywords", systemImage: "tag") { isBrowsing = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(known.isEmpty)
                .help(known.isEmpty ? "No keyword is in use yet" : "Pick among the keywords in use")
                .popover(isPresented: $isBrowsing, arrowEdge: .bottom) {
                    KeywordBrowser(keywords: $keywords, known: known)
                }
        }
    }
}

/// Every keyword in use, as tags to click: a click gives the keyword, another takes it back. A
/// field narrows them down when there are many.
struct KeywordBrowser: View {
    @Binding var keywords: [String]
    let known: [String]

    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if known.count > 12 {
                TextField("Filter", text: $filter, prompt: Text("Filter keywords"))
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                TagFlow(spacing: 6) {
                    ForEach(shown, id: \.self) { keyword in
                        let isChosen = chosen.contains(keyword.lowercased())
                        Button { toggle(keyword) } label: {
                            Text(keyword)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                .background(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .overlay {
                if shown.isEmpty {
                    Text("No Keyword Found").foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var chosen: Set<String> {
        Set(keywords.map { $0.lowercased() })
    }

    private var shown: [String] {
        let typed = filter.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? known : known.filter { $0.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func toggle(_ keyword: String) {
        if let index = keywords.firstIndex(where: { $0.lowercased() == keyword.lowercased() }) {
            keywords.remove(at: index)
        } else {
            keywords.append(keyword)
        }
    }
}

/// Lays tags out one after the other, going to the next line when the width is used up.
struct TagFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let frames = frames(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? (frames.map(\.maxX).max() ?? 0), height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (subview, frame) in zip(subviews, frames(in: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(in width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

#Preview("Browser") {
    @Previewable @State var keywords = ["Venice"]
    KeywordBrowser(keywords: $keywords, known: ["Burano", "family", "long exposure", "Murano", "night", "November", "Venice", "Vienna"])
}

#Preview {
    @Previewable @State var keywords = ["Venice", "night"]
    KeywordTokenField(keywords: $keywords, suggestions: ["Venice", "Vienna", "night", "family"])
        .frame(width: 300)
        .padding()
}
