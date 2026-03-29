import Foundation

enum FirstRunManager {
    private static let key = "setup_completed"

    static var isFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: key)
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
