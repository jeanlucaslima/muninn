import AppKit

/// Writes content to the system clipboard with a marker so the daemon
/// can distinguish Muninn-initiated writes from user copies.
public enum ClipboardWriter {
    public static func write(_ content: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        pasteboard.setData(Data(), forType: MuninnPaths.pasteboardMarkerType)
    }
}
