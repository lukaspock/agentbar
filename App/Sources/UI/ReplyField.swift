import SwiftUI
import AppKit

/// Text field for question replies. The owning panel is non-key by default; it becomes key only when this field is clicked.
struct ReplyField: NSViewRepresentable {
    var placeholder: String
    var onEditing: (Bool) -> Void
    var onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BarTextField {
        let f = BarTextField()
        f.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 13)])
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = .white
        f.font = .systemFont(ofSize: 13)
        f.delegate = context.coordinator
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        return f
    }

    func updateNSView(_ nsView: BarTextField, context: Context) { context.coordinator.parent = self }

    static func dismantleNSView(_ nsView: BarTextField, coordinator: Coordinator) {
        if coordinator.editing { coordinator.editing = false; coordinator.parent.onEditing(false) }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReplyField
        var editing = false
        init(_ parent: ReplyField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            editing = true
            (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = .white
            parent.onEditing(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            editing = false
            parent.onEditing(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parent.onSubmit(text) }
            return true
        }
    }
}

final class BarTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let panel = window as? BarPanel {
            panel.allowKey = true
            panel.makeKey()
        }
        super.mouseDown(with: event)
    }
}
