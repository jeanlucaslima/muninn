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

    // MARK: - Bundled Executables

    private static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var executableDirectory: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }

    public static var helperExecutablePath: String? {
        resolveExecutable(named: "muninnd")
    }

    public static var cliExecutablePath: String? {
        resolveExecutable(named: "muninn")
    }

    private static func resolveExecutable(named name: String) -> String? {
        guard let dir = executableDirectory else { return nil }
        let path = dir.appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if isAppBundle {
            return nil
        }
        let devPath = ProcessInfo.processInfo.arguments[0]
        let devDir = URL(fileURLWithPath: devPath).deletingLastPathComponent()
        let devBinary = devDir.appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: devBinary) {
            return devBinary
        }
        return nil
    }
}
