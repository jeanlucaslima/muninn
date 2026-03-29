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

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 0x7E: // Up arrow
            keyDelegate?.searchFieldMoveUp()
        case 0x7D: // Down arrow
            keyDelegate?.searchFieldMoveDown()
        case 0x24: // Return
            keyDelegate?.searchFieldConfirm()
        case 0x35: // Escape
            keyDelegate?.searchFieldCancel()
        case 0x33 where flags.contains(.command): // Cmd+Delete
            keyDelegate?.searchFieldDeleteEntry()
        case 0x23 where flags == [.command, .shift]: // Cmd+Shift+P
            keyDelegate?.searchFieldTogglePause()
        case 0x23 where flags == .command: // Cmd+P
            keyDelegate?.searchFieldTogglePin()
        default:
            super.keyDown(with: event)
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

        // Become first responder on appear
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
    }
}
