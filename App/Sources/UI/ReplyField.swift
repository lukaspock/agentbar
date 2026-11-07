import SwiftUI
import AppKit

/// Text field for question replies. The owning panel is non-key by default; it becomes key only when this field is clicked.
struct ReplyField: NSViewRepresentable {
    var placeholder: String
    var onEditing: (Bool) -> Void
    var onSubmit: (String) -> Void
    /// Optional: max characters (typing/pasting beyond it is cut off).
    var maxLength: Int?
    /// Optional: when set, Enter calls this instead of `onSubmit`; the field is cleared only if it returns true.
    var onSubmitAccepted: ((String) -> Bool)?
    /// Optional: called with the current length while typing (character counter).
    var onLength: ((Int) -> Void)?

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

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if let max = parent.maxLength, field.stringValue.count > max {
                field.stringValue = String(field.stringValue.prefix(max))
            }
            parent.onLength?(field.stringValue.count)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            editing = false
            parent.onEditing(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            if let accept = parent.onSubmitAccepted {
                if accept(text) { textView.string = ""; parent.onLength?(0) }
            } else {
                parent.onSubmit(text)
            }
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
