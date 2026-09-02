import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 兜底：确保应用以菜单栏常驻方式运行，不占用 Dock
        NSApp.setActivationPolicy(.accessory)
        Task {
            await CoreStore.shared.bootstrap()
            // bootstrap 失败时 repository 为 nil，错误已由 CoreStore 记录并在设置页呈现
            guard let repository = CoreStore.shared.repository else { return }
            let monitor = ClipboardMonitor(appState: appState, repository: repository)
            monitor.start()
            clipboardMonitor = monitor

            // 调试 / 自动化测试钩子：传入 -AidoPasteShowWindowOnLaunch 时启动即显示主窗口
            if ProcessInfo.processInfo.arguments.contains("-AidoPasteShowWindowOnLaunch") {
                WindowManager.shared.showClipboardWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // §61：退出时先停止监听；仓储操作都是同步落库，无需额外 flush
        clipboardMonitor?.stop()
        return .terminateNow
    }
}
