import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var clipboardMonitor: ClipboardMonitor?
    private let globalShortcutManager = GlobalShortcutManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 兜底：确保应用以菜单栏常驻方式运行，不占用 Dock
        NSApp.setActivationPolicy(.accessory)
        Task {
            await CoreStore.shared.bootstrap()
            // §53：失败必须可见——数据库不可用时弹窗说明，而不是菜单栏点击无响应
            guard let repository = CoreStore.shared.repository else {
                if let error = CoreStore.shared.startupError {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "AidoPaste 数据库初始化失败"
                    alert.informativeText = error.errorDescription ?? "请重启应用再试。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
                return
            }
            let monitor = ClipboardMonitor(appState: appState, repository: repository)
            monitor.start()
            clipboardMonitor = monitor

            // §32/§50：启动清扫一次，此后每 6 小时一轮
            CleanupScheduler.shared.configure(repository: repository)

            registerGlobalShortcut()

            // 调试 / 自动化测试钩子：传入 -AidoPasteShowWindowOnLaunch 时启动即显示主窗口
            if ProcessInfo.processInfo.arguments.contains("-AidoPasteShowWindowOnLaunch") {
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
