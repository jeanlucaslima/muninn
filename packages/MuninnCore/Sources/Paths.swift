import Foundation
import AppKit

public enum MuninnPaths {
    /// Pasteboard type used to mark clipboard writes made by Muninn itself.
    /// The watcher checks for this to avoid recording self-generated changes.
    public static let pasteboardMarkerType = NSPasteboard.PasteboardType("com.muninn.self-copy")

    public static var applicationSupportDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Muninn"
    }

    public static var databasePath: String {
        "\(applicationSupportDir)/muninn.db"
    }

    public static var socketPath: String {
        ProcessInfo.processInfo.environment["MUNINN_SOCKET_PATH"]
            ?? "\(applicationSupportDir)/muninn.sock"
    }

    public static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            atPath: applicationSupportDir,
            withIntermediateDirectories: true
        )
    }
}
