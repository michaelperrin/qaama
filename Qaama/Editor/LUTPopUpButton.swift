import AppKit
import EditorKit
import SwiftUI

/// The pop-up button that chooses the layer's LUT, with what a SwiftUI `Picker` can't do: it tells
/// which item the pointer or the arrow keys are on while the menu is open, so the canvas can show
/// each table before one is chosen. AppKit's own `NSPopUpButton`; only its menu's delegate is ours.
struct LUTPopUpButton: NSViewRepresentable {
    /// The tables of the library, in the order to list them.
    let names: [String]
    /// The table of the layer being edited; it may no longer be in the library.
    let selection: String?
    /// The item highlighted in the open menu; nil when none is, and once the menu has closed.
    let onHighlight: (EditorModel.LUTChoice?) -> Void
    let onChoose: (EditorModel.LUTChoice) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.lineBreakMode = .byTruncatingTail
        // The column decides the width, not the longest name (see AGENTS.md on the inspector).
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        button.setAccessibilityLabel(String(localized: "LUT"))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onHighlight = onHighlight
        context.coordinator.onChoose = onChoose
        context.coordinator.show(names: names, selection: selection, in: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context _: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        // Without a width to fill, a modest one: the natural width follows the longest name.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? min(fitting.width, Self.idealWidth)
        return CGSize(width: width, height: fitting.height)
    }

    private static let idealWidth: CGFloat = 160

    final class Coordinator: NSObject, NSMenuDelegate {
        var onHighlight: (EditorModel.LUTChoice?) -> Void = { _ in }
        var onChoose: (EditorModel.LUTChoice) -> Void = { _ in }
        /// What the menu was last built from: it is rebuilt only when this changes, never under
        /// the pointer for an unrelated update of the inspector.
        private var shown: (names: [String], selection: String?)?

        func show(names: [String], selection: String?, in button: NSPopUpButton) {
            if let shown, shown.names == names, shown.selection == selection {
                return
            }
            shown = (names, selection)
            guard let menu = button.menu else { return }
            menu.removeAllItems()
            menu.addItem(item(String(localized: "None"), .none))
            if !names.isEmpty || selection != nil {
                menu.addItem(.separator())
            }
            // A table the photo names but the library no longer has: shown for what it is.
            if let selection, !names.contains(selection) {
                menu.addItem(item(String(localized: "\(selection) (Missing)"), .table(selection)))
            }
            for name in names {
                menu.addItem(item(name, .table(name)))
            }
            let chosen: EditorModel.LUTChoice = selection.map { .table($0) } ?? .none
            button.select(menu.items.first { $0.representedObject as? EditorModel.LUTChoice == chosen })
        }

        private func item(_ title: String, _ choice: EditorModel.LUTChoice) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice
            return item
        }

        @objc func choose(_ sender: NSPopUpButton) {
            guard let choice = sender.selectedItem?.representedObject as? EditorModel.LUTChoice else { return }
            // The button shows the new choice by itself; the inspector's update confirms it.
            shown?.selection = if case let .table(name) = choice {
                name
            } else {
                nil
            }
            onChoose(choice)
        }

        func menu(_: NSMenu, willHighlight item: NSMenuItem?) {
            onHighlight(item?.representedObject as? EditorModel.LUTChoice)
        }

        func menuDidClose(_: NSMenu) {
            // After the button's action, which follows the closing of the menu: a choice replaces
            // the preview itself, and going back to the previous look first would flash.
            Task { @MainActor in self.onHighlight(nil) }
        }
    }
}
