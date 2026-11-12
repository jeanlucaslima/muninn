import Foundation

public enum MuninnPaths {
    /// Pasteboard type Muninn adds to its own writes, carrying the item id (§4.8).
    public static let selfCopyMarkerType = "com.muninn.self-copy"

    /// Dev builds are isolated, not weakened (§4.1): a `DEBUG` build uses its
    /// own data directory, decided at compile time.
    #if DEBUG
    public static let isDevBuild = true
    private static let dataDirectoryName = "Muninn-Dev"
    #else
    public static let isDevBuild = false
    private static let dataDirectoryName = "Muninn"
    #endif

    public static var applicationSupportDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/\(dataDirectoryName)"
    }

    public static var databasePath: String {
        "\(applicationSupportDir)/muninn.db"
    }

    public static var socketPath: String {
        #if DEBUG
        // Test seam for the CLI process tests; compiled out of release builds.
        // Removed with the v1 socket transport (design §2).
        if let override = ProcessInfo.processInfo.environment["MUNINN_SOCKET_PATH"] {
            return override
        }
        #endif
        return "\(applicationSupportDir)/muninn.sock"
    }

    /// Creates the data directory and keeps Spotlight out of it (§4.16).
    public static func ensureDirectoryExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: applicationSupportDir, withIntermediateDirectories: true)
        let marker = "\(applicationSupportDir)/.metadata_never_index"
        if !fm.fileExists(atPath: marker) {
            fm.createFile(atPath: marker, contents: Data())
        }
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
