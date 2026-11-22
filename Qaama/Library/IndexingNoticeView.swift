import LibraryKit
import SwiftUI

/// A bar above the grid while background indexing makes the listing provisional: says what may still
/// change, and how far the indexing is. Also what says, above the deleted photos, what Recently
/// Deleted is, with what can be done to all of them.
struct IndexingNoticeView: View {
    /// A button at the trailing end of the bar.
    struct Action {
        let title: String
        let help: String
        var isDisabled = false
        let run: () -> Void
    }

    let notice: String
    let progress: IndexingProgress?
    var action: Action?

    var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("\(progress.done.formatted()) of \(progress.total.formatted()) photos indexed")
            }
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .disabled(action.isDisabled)
                    .help(action.help)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

#Preview("Indexing") {
    IndexingNoticeView(notice: "Still indexing the Photos library: some JPEG twins of RAW photos may show until it finishes.",
                       progress: IndexingProgress(done: 12400, total: 74065))
        .frame(width: 700)
}
