import AppKit
import SwiftUI

/// The system search field (magnifying glass, Clear button, the look of the day), for a search
/// that lives next to its results instead of in a toolbar. SwiftUI only offers the component
/// through `.searchable`, which belongs to a toolbar, hence AppKit.
///
/// It takes the keyboard as soon as it is shown, and hands over the keys a list of results needs:
/// the keyboard can stay in the field while the arrows walk the results.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// Large in a dialog of its own, regular in a panel.
    var controlSize: NSControl.ControlSize = .large
    /// The height below the field to bring into view with it when it takes the keyboard, for what
    /// follows it in a panel that scrolls; 0 leaves the scrolling alone.
    var revealedBelow: CGFloat = 0
    /// The up (-1) and down (1) arrow keys, which a single line has no use for.
    var onMove: (Int) -> Void = { _ in }
    /// The Return key.
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.revealedBelow = revealedBelow
        field.controlSize = controlSize
        field.placeholderString = prompt
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        // Not while it is the one changing: writing the text back would move the insertion point.
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = prompt
        field.controlSize = controlSize
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField {
                parent.text = field.stringValue
            }
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            default:
                return false
            }
            return true
        }
    }
}

/// A search field that is typed in as soon as its window shows it.
private final class FocusedSearchField: NSSearchField {
    var revealedBelow: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        guard revealedBelow > 0 else { return }
        // Once the panel has laid out the rows that come with the field.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The room below the field: further down the y axis when the view is flipped, up it otherwise.
            let y = isFlipped ? bounds.minY : bounds.minY - revealedBelow
            scrollToVisible(NSRect(x: 0, y: y, width: bounds.width, height: bounds.height + revealedBelow))
        }
    }
}
