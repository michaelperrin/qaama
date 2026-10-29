import SwiftUI

/// Comma-separated keywords. Saved on Return, each time a comma closes a keyword, when the field
/// loses focus, and when the view goes away: on macOS a click on the canvas or a button doesn't
/// move the keyboard focus, so focus loss alone is not enough.
struct KeywordsField: View {
    let keywords: [String]
    let onCommit: ([String]) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Keywords", text: $text, prompt: Text("Keywords, comma separated"))
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: text) { _, new in
                if new.hasSuffix(",") {
                    commit()
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: keywords, initial: true) { _, new in
                // Don't disturb a keyword being typed; the committed ones are already in the text.
                if !isFocused {
                    text = new.joined(separator: ", ")
                }
            }
            .onDisappear(perform: commit)
            .help("Keywords (comma separated). Return or a comma saves.")
    }

    private func commit() {
        let parsed = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != keywords {
            onCommit(parsed)
        }
    }
}
