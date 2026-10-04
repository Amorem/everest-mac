import ServiceManagement

/// "Open at login", the system way (System Settings > General > Login Items):
/// the signed app registers itself — no LaunchAgent to maintain.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var enabled: Bool { status == .enabled }

    static func set(_ on: Bool) throws {
        if on {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
