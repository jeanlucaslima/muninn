import AppKit
import MuninnCore

/// Puts a stored item back on a pasteboard (`copy`, or a pick in the panel).
/// Adds the self-copy marker with the item id and `org.nspasteboard.source`,
/// so the monitor records exactly one `muninn` event (§4.8).
@MainActor
public enum PasteboardWriter {
    public static let sourceBundleID = "com.muninn"

    /// Returns the pasteboard's changeCount after the write.
    @discardableResult
    public static func write(itemID: Int64, representations: [RepresentationInput], to pasteboard: NSPasteboard = .general) -> Int {
        let main = NSPasteboardItem()
        var fileItems: [NSPasteboardItem] = []

        for rep in representations {
            let type = NSPasteboard.PasteboardType(rep.uti)
            switch rep.payload {
            case .text(let string):
                main.setString(string, forType: type)
            case .data(let data):
                main.setData(data, forType: type)
            case .fileURL(let url, _, _):
                if fileItems.isEmpty && main.types.isEmpty {
                    main.setString(url, forType: type)
                    fileItems.append(main)
                } else {
                    let item = NSPasteboardItem()
                    item.setString(url, forType: type)
                    fileItems.append(item)
                }
            case .omitted:
                continue
            }
        }
        main.setString(String(itemID), forType: NSPasteboard.PasteboardType(MuninnPaths.selfCopyMarkerType))
        main.setString(sourceBundleID, forType: NSPasteboard.PasteboardType(CapturePolicy.sourceType))

        let items = fileItems.first === main ? fileItems : [main] + fileItems
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }
}
