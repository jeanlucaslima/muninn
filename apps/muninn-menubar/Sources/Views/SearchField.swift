import AppKit
import SwiftUI

protocol SearchFieldDelegate: AnyObject {
    func searchFieldDidChange(_ text: String)
    func searchFieldMoveUp()
    func searchFieldMoveDown()
    func searchFieldConfirm()
    func searchFieldCancel()
    func searchFieldDeleteEntry()
    func searchFieldTogglePin()
    func searchFieldTogglePause()
}

final class MuninnSearchField: NSTextField {
    weak var keyDelegate: SearchFieldDelegate?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 0x33 where flags.contains(.command): // Cmd+Delete
            keyDelegate?.searchFieldDeleteEntry()
            return true
        case 0x23 where flags == [.command, .shift]: // Cmd+Shift+P
            keyDelegate?.searchFieldTogglePause()
            return true
        case 0x23 where flags == .command: // Cmd+P
            keyDelegate?.searchFieldTogglePin()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    weak var keyDelegate: SearchFieldDelegate?

    func makeNSView(context: Context) -> MuninnSearchField {
        let field = MuninnSearchField()
        field.placeholderString = "Search clipboard..."
        field.isBordered = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.backgroundColor = .clear
        field.delegate = context.coordinator
        field.keyDelegate = keyDelegate
        return field
    }

    func updateNSView(_ nsView: MuninnSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.keyDelegate = keyDelegate

        DispatchQueue.main.async {
            if let window = nsView.window, window.firstResponder != nsView.currentEditor() {
                window.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.keyDelegate?.searchFieldDidChange(field.stringValue)
        }

        // Intercept commands from the field editor — this is where arrow keys,
        // Return, and Escape actually arrive while the text field is being edited.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.keyDelegate?.searchFieldMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.keyDelegate?.searchFieldMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.keyDelegate?.searchFieldConfirm()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.keyDelegate?.searchFieldCancel()
                return true
            default:
                return false
            }
        }
    }
}
