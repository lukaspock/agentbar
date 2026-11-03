import SwiftUI
import AppKit

/// Single-line text field for the notch panel (workspace name, inline rename). Like `ReplyField` it makes the otherwise
/// non-key panel key on click; unlike it, it edits a binding, can grab focus when it appears and reports Esc.
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var limit = 200
    var focusOnAppear = false
    var onEditing: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Called when editing ends without Return/Esc (focus moved away).
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InlineNSTextField {
        let f = InlineNSTextField()
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
        f.stringValue = text
        f.wantsFocusOnAppear = focusOnAppear
        return f
    }

    func updateNSView(_ nsView: InlineNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text, !context.coordinator.editing { nsView.stringValue = text }
    }

    static func dismantleNSView(_ nsView: InlineNSTextField, coordinator: Coordinator) {
        if coordinator.editing { coordinator.editing = false; coordinator.parent.onEditing(false) }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        var editing = false
        private var finished = false
        init(_ parent: InlineTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            editing = true
            (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = .white
            parent.onEditing(true)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            if f.stringValue.count > parent.limit { f.stringValue = String(f.stringValue.prefix(parent.limit)) }
            parent.text = f.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            let wasEditing = editing
            editing = false
            parent.onEditing(false)
            // Return/Esc already reported themselves; this is the "focus moved away" path.
            if wasEditing, !finished { parent.onEnd() }
            finished = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                finished = true
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class InlineNSTextField: NSTextField {
    var wantsFocusOnAppear = false
    private var focused = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        takeKey()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocusOnAppear, !focused, window != nil else { return }
        focused = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.takeKey()
            window.makeFirstResponder(self)
        }
    }

    private func takeKey() {
        if let panel = window as? BarPanel {
            panel.allowKey = true
            panel.makeKey()
        }
    }
}
