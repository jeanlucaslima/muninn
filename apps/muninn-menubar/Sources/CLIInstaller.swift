import Foundation
import MuninnCore

enum CLIInstallResult {
    case installed(String)
    case failed(String)
}

enum CLIInstaller {
    private static let targetPaths = [
        "/usr/local/bin/muninn",
        "/opt/homebrew/bin/muninn",
    ]

    static func install() -> CLIInstallResult {
        guard let source = MuninnPaths.cliExecutablePath else {
            return .failed("CLI binary not found in app bundle.")
        }

        let fm = FileManager.default

        for target in targetPaths {
            if let result = tryInstall(source: source, target: target, fm: fm) {
                return result
            }
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let localBin = "\(home)/.local/bin"
        let target = "\(localBin)/muninn"

        do {
            try fm.createDirectory(atPath: localBin, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create \(localBin).")
        }

        if let result = tryInstall(source: source, target: target, fm: fm) {
            if case .installed = result {
                return .installed("\(target) (you may need to add ~/.local/bin to your PATH)")
            }
            return result
        }

        return .failed("Could not install CLI to any location.")
    }

    private static func tryInstall(source: String, target: String, fm: FileManager) -> CLIInstallResult? {
        let dir = (target as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: dir) else { return nil }

        if fm.fileExists(atPath: target) {
            var isSymlink = false
            if let attrs = try? fm.attributesOfItem(atPath: target),
               let type = attrs[.type] as? FileAttributeType {
                isSymlink = (type == .typeSymbolicLink)
            }

            if !isSymlink {
                return nil
            }

            try? fm.removeItem(atPath: target)
        }

        do {
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            return .installed(target)
        } catch {
            return nil
        }
    }
}
