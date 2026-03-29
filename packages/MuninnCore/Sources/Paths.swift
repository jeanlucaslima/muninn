import Foundation

public enum MuninnPaths {
    public static var applicationSupportDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Muninn"
    }

    public static var databasePath: String {
        "\(applicationSupportDir)/muninn.db"
    }

    public static var socketPath: String {
        "\(applicationSupportDir)/muninn.sock"
    }

    public static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            atPath: applicationSupportDir,
            withIntermediateDirectories: true
        )
    }
}
