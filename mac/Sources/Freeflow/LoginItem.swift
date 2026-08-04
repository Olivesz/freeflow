import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Registers the app itself as a
/// login item — no separate helper bundle needed.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("freeflow: login-item toggle failed: \(error.localizedDescription)")
        }
    }
}
