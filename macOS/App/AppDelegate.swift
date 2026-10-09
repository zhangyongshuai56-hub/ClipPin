import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var clipboardMonitor: ClipboardMonitor?
    private let globalShortcutManager = GlobalShortcutManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 原生数据层自测：-PasteSelfTest 在临时库上跑关键断言后退出（退出码 0 / 1）
        if ProcessInfo.processInfo.arguments.contains("-PasteSelfTest") {
            let passed = PasteSelfTest.run()
            exit(passed ? 0 : 1)
        }
        // LSUIElement 兜底：确保应用以菜单栏常驻方式运行，不占用 Dock
        NSApp.setActivationPolicy(.accessory)
        // 0.2.0 改名迁移：接管旧 AidoPaste 的数据目录与用户偏好（幂等）
        LegacyMigrator.migrateIfNeeded()
        Task {
            await CoreStore.shared.bootstrap()
            // §53：失败必须可见——数据库不可用时弹窗说明，而不是菜单栏点击无响应
            guard let repository = CoreStore.shared.repository else {
                if let error = CoreStore.shared.startupError {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "Paste 数据库初始化失败"
                    alert.informativeText = error.errorDescription ?? "请重启应用再试。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
                return
            }
            let monitor = ClipboardMonitor(appState: appState, repository: repository)
            monitor.start()
            clipboardMonitor = monitor

            // §32/§50：启动清扫一次，此后按用户自定义频率轮询（默认每 1 小时）
            CleanupScheduler.shared.configure(repository: repository)

            registerGlobalShortcut()

            // 调试 / 自动化测试钩子：传入 -PasteShowWindowOnLaunch 时启动即显示主窗口
            if ProcessInfo.processInfo.arguments.contains("-PasteShowWindowOnLaunch") {
                WindowManager.shared.showClipboardWindow()
            }
        }
    }

    /// 注册全局快捷键（§26；用户自定义组合，默认 ⌘⇧V）。
    private func registerGlobalShortcut() {
        do {
            try globalShortcutManager.register(.stored) {
                WindowManager.shared.toggleClipboardWindow()
            }
        } catch {
            // 不中断启动；错误信息已由 manager 记录
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // §61：退出时先停止监听与调度；仓储操作都是同步落库，无需额外 flush
        clipboardMonitor?.stop()
        CleanupScheduler.shared.stop()
        return .terminateNow
    }
}
