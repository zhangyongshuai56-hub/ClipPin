import ServiceManagement

/// 登录时启动。使用 macOS 官方 SMAppService 机制，不写 LaunchAgents、不用脚本 hack。
enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 注册 / 注销失败会抛错，由调用方展示给用户，不静默失败。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
