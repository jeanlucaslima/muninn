import ServiceManagement

enum LoginItemManager {
    static func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            print("muninn: failed to enable login item: \(error)")
            return false
        }
    }

    static func disable() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            print("muninn: failed to disable login item: \(error)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
